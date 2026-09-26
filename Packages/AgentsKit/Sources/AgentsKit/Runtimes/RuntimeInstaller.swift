import AgentsKitCore
import Foundation

/// What the daemon installs a missing runtime with (048). A protocol so the daemon's own
/// bookkeeping — one install per runtime, the notifications — is tested without a network.
public protocol RuntimeInstalling: Sendable {
    /// The recipe this Mac can actually carry out for `runtime`, or nil when all the app
    /// can offer is the vendor's page.
    func recipe(for runtime: Runtime) -> RuntimeInstall?
    /// Install it and say where it ended up: `.available`, or `.installFailed` with why.
    func install(_ runtime: Runtime, progress: @escaping @Sendable (String) -> Void) async -> RuntimeAvailability
}

/// Installs the runtimes in `RuntimeCatalog` on this Mac, each its own way: Claude from
/// the app's pinned toolset, the rest with the vendor's own script or npm.
///
/// Whatever the recipe, the result is decided by looking again with the same discovery
/// the app uses: a script that exits 0 and leaves nothing where the app looks is a
/// failure, said as one, not a success nobody can start.
public struct RuntimeInstaller: RuntimeInstalling {
    public var discovery: RuntimeDiscovery
    /// Nil when the app's bundle carries no toolset, as in `swift run` or a build without
    /// its resources. Claude then gets its page and no button.
    public var toolset: MacToolsetInstaller?
    public var environment: [String: String]
    public var timeout: Duration

    public init(discovery: RuntimeDiscovery,
                toolset: MacToolsetInstaller?,
                environment: [String: String] = LoginShellPath.installEnvironment(),
                timeout: Duration = .seconds(300)) {
        self.discovery = discovery
        self.toolset = toolset
        self.environment = environment
        self.timeout = timeout
    }

    public func recipe(for runtime: Runtime) -> RuntimeInstall? {
        switch runtime.install {
        case .toolset:
            return toolset?.toolset.macNode == nil ? nil : runtime.install
        case .npmGlobal:
            return npm == nil ? nil : runtime.install
        case .script, nil:
            return runtime.install
        }
    }

    public func install(_ runtime: Runtime, progress: @escaping @Sendable (String) -> Void) async -> RuntimeAvailability {
        guard let recipe = recipe(for: runtime) else {
            return .installFailed(reason: "The app can’t install \(runtime.name) itself.")
        }
        do {
            switch recipe {
            case .toolset:
                guard let toolset else { return .installFailed(reason: "The app can’t install \(runtime.name) itself.") }
                try await toolset.install(progress: progress)
            case .script(let url, let shell):
                progress("Running \(url.host() ?? "the vendor")’s installer")
                try await runScript(url, shell: shell, for: runtime)
            case .npmGlobal(let package):
                progress("Installing \(package) with npm")
                try await runNPM(package, for: runtime)
            }
        } catch let failure as MacToolsetInstaller.Failure {
            return .installFailed(reason: failure.sentence)
        } catch let failure as Failure {
            return .installFailed(reason: failure.sentence)
        } catch {
            return .installFailed(reason: "Installing \(runtime.name) failed: \(error.localizedDescription)")
        }
        let found = discovery.locate(runtime)
        guard found.isAvailable else {
            let places = discovery.searchPaths.prefix(4).joined(separator: ", ")
            return .installFailed(reason: "\(runtime.name) installed, but not where the app looks: \(places)…")
        }
        return found
    }

    enum Failure: Error {
        case script(name: String, detail: String)
        case timedOut(name: String)
        case npmCannotWrite
        case npm(String)

        var sentence: String {
            switch self {
            case .script(let name, let detail):
                detail.isEmpty ? "\(name)’s installer failed." : "\(name)’s installer failed: \(detail)"
            case .timedOut(let name):
                "\(name)’s installer took more than five minutes, so it was stopped."
            case .npmCannotWrite:
                "npm can’t write its global folder."
            case .npm(let detail):
                "npm couldn’t install it: \(detail)"
            }
        }
    }

    /// `curl -fsSL <url> | <shell>`, with pipefail so a download that fails is the
    /// failure rather than an empty script that "succeeds".
    private func runScript(_ url: URL, shell: String, for runtime: Runtime) async throws {
        let outcome = try await InstallStep(
            executable: "/bin/bash",
            arguments: ["-c", #"set -o pipefail; curl -fsSL "$1" | "$2""#, "install", url.absoluteString, shell],
            environment: environment,
            directory: FileManager.default.homeDirectoryForCurrentUser,
            timeout: timeout).run()
        if outcome.timedOut { throw Failure.timedOut(name: runtime.name) }
        guard outcome.status == 0 else { throw Failure.script(name: runtime.name, detail: outcome.tail(3)) }
    }

    private func runNPM(_ package: String, for runtime: Runtime) async throws {
        guard let npm else { throw Failure.npm("there is no npm on this Mac") }
        let outcome = try await InstallStep(executable: npm, arguments: ["install", "-g", package],
                                            environment: environment, timeout: timeout).run()
        if outcome.timedOut { throw Failure.timedOut(name: runtime.name) }
        guard outcome.status == 0 else {
            // Not retried with sudo: an app asking for an admin password to write into
            // somebody's npm is not a thing this should do on its own.
            if outcome.output.contains("EACCES") { throw Failure.npmCannotWrite }
            throw Failure.npm(outcome.lastLine)
        }
    }

    private var npm: String? {
        discovery.searchPaths.lazy
            .map { ($0 as NSString).appendingPathComponent("npm") }
            .first { discovery.fileExists($0) }
    }
}
