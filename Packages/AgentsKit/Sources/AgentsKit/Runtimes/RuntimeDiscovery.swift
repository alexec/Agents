import Foundation

/// What can be started on this Mac, and what to say about what cannot.
public struct RuntimeDiscovery: Sendable {
    public var searchPaths: [String]
    public var fileExists: @Sendable (String) -> Bool
    /// On a server (`--serve`), the home whose `.agents-server/tools/` holds the toolsets
    /// the app installed (043). Nil on the Mac, which never looks there.
    public var serverHome: String?
    /// On the Mac, the daemon's own `tools/` folder, where the app installs the Claude
    /// toolset for somebody with no Node (048). Consulted after the person's own PATH, so
    /// anyone who already has `npx` goes on using it.
    public var macToolsHome: String?

    public init(searchPaths: [String]? = nil,
                fileExists: (@Sendable (String) -> Bool)? = nil) {
        self.searchPaths = searchPaths ?? LoginShellPath.directories()
        self.fileExists = fileExists ?? { path in
            FileManager.default.isExecutableFile(atPath: path)
        }
    }

    /// Cheap: does the thing we would run exist. No process is started, because
    /// starting three runtimes to draw a list would make opening the app slow and, for
    /// the Claude adapter on a cold npm cache, very slow.
    public func locate(_ runtime: Runtime) -> RuntimeAvailability {
        // The app's own toolset first, when it is whole: its `npx` is a shim that runs the
        // pinned adapter and reaches for no network (043, R4). Then the person's own.
        if let serverHome {
            let current = "\(serverHome)/\(Toolset.serverFolder(runtimeID: runtime.id))/current"
            let shim = "\(current)/bin/\(runtime.executable)"
            if FileManager.default.fileExists(atPath: "\(current)/ok"), fileExists(shim) {
                return .available(path: shim, supportsResume: false)
            }
        }
        if runtime.executable.contains("/") {
            return fileExists(runtime.executable)
                ? .available(path: runtime.executable, supportsResume: false)
                : .missing(lookedIn: [runtime.executable])
        }
        for directory in searchPaths {
            let candidate = (directory as NSString).appendingPathComponent(runtime.executable)
            if fileExists(candidate) {
                return .available(path: candidate, supportsResume: false)
            }
        }
        if let shim = appToolset(for: runtime) {
            return .available(path: shim, supportsResume: false)
        }
        return .missing(lookedIn: searchPaths)
    }

    /// The Mac's own copy of a toolset, when it is whole: `current/ok` and an executable
    /// shim, the same test as a server's.
    public func appToolset(for runtime: Runtime) -> String? {
        guard let macToolsHome else { return nil }
        let current = "\(macToolsHome)/\(runtime.id)/current"
        let shim = "\(current)/bin/\(runtime.executable)"
        guard FileManager.default.fileExists(atPath: "\(current)/ok"), fileExists(shim) else { return nil }
        return shim
    }

    public func statuses(for runtimes: [Runtime] = RuntimeCatalog.builtIn) -> [RuntimeStatus] {
        runtimes.map { RuntimeStatus(runtime: $0, availability: locate($0)) }
    }

    /// The expensive half: start the runtime and shake hands, which is the only way to
    /// learn whether it can resume a session and what it says about signing in.
    ///
    /// Note what this deliberately does not conclude. Copilot advertises
    /// `copilot-login` in `authMethods` while perfectly signed in, so the presence of
    /// auth methods proves nothing at all. Telling "installed but signed out" from
    /// "installed and ready" needs a failed `session/new`, and how a signed-out runtime
    /// actually fails is not documented and has not been confirmed.
    public func probe(_ runtime: Runtime, at path: String, cwd: URL) async -> RuntimeAvailability {
        do {
            let session = try ACPSession.launch(executable: URL(fileURLWithPath: path),
                                                arguments: runtime.arguments,
                                                cwd: cwd,
                                                environment: LoginShellPath.environment())
            let result = try await session.initialize()
            await session.end(gracePeriod: .seconds(2))
            return .available(path: path, supportsResume: result.supportsResume)
        } catch {
            return .failed(reason: String(describing: error))
        }
    }
}
