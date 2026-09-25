import AgentsKitCore
import Foundation

/// The binary a server should be running, and what identifies it (037).
public struct ServerBinary: Sendable, Equatable {
    public var file: URL
    public var sha256: String
    /// The app's `MARKETING_VERSION+CURRENT_PROJECT_VERSION`, only for refusing a server
    /// a newer app set up. Equality is by checksum.
    public var version: String

    public init(file: URL, sha256: String, version: String) {
        self.file = file
        self.sha256 = sha256
        self.version = version
    }
}

/// One server, from nothing to a daemon answering through the forward (037).
///
/// `connect()` is the whole sequence: master up, probe, refuse what cannot be used,
/// install or update what is missing or stale, forward the daemon's socket, and connect
/// the client through it (starting the daemon if nothing answers). It never throws: the
/// outcome is `state`, which the window draws. It does not retry either; the window
/// decides when to try again, because it is the one that knows the Mac just woke.
public actor ServerConnection {
    public enum State: Sendable, Equatable {
        case idle
        case connecting(Step)
        case connected
        /// The master went after being connected. The server's agents carry on.
        case offline(since: Date)
        /// Something ssh or the probe named, which retrying will not fix by itself.
        case failed(HostProblem)
        /// Running an older binary with a turn in flight; the swap waits for it.
        case updateWaiting
    }

    public enum Step: String, Sendable, Equatable {
        case connect, checkSystem, setUp, findRuntimes
    }

    public nonisolated let hostID: HostID
    public nonisolated let client: DaemonClient
    public private(set) var state: State = .idle
    public private(set) var facts: ServerFacts?

    private nonisolated let master: SSHMaster
    private let installer: ServerInstaller
    private let binary: @Sendable (Architecture) async -> ServerBinary?
    private let installedBy: String
    private var onState: (@Sendable (State) async -> Void)?
    private var wasConnected = false
    private var isConnecting = false

    /// - Parameters:
    ///   - ssh: the host's command, its control path under `<root>/hosts/`.
    ///   - socket: the forward's local end, `<root>/hosts/<id>.sock`.
    ///   - binary: what to install on a server of this architecture; nil when the app
    ///     has none for it.
    public init(hostID: HostID, ssh: SSHCommand, socket: URL, installedBy: String,
                binary: @escaping @Sendable (Architecture) async -> ServerBinary?) {
        self.hostID = hostID
        let master = SSHMaster(command: ssh, socket: socket)
        let installer = ServerInstaller(ssh: ssh)
        self.master = master
        self.installer = installer
        self.binary = binary
        self.installedBy = installedBy
        self.client = DaemonClient(link: ServerLink(socket: socket, installer: installer) {
            await master.isRunning
        })
    }

    /// The app is quitting: let the ssh master go. The server's daemon stays up.
    public nonisolated func stopForQuit() { master.stopWithoutWaiting() }

    public func setOnState(_ handler: @escaping @Sendable (State) async -> Void) {
        onState = handler
    }

    public func connect() async {
        // One at a time. A retry arriving while a connect is under way (the network
        // monitor fires the moment it starts) would start a second master over the
        // first and fail both.
        guard !isConnecting else { return }
        isConnecting = true
        defer { isConnecting = false }
        do {
            try await run()
        } catch let problem as HostProblem {
            await master.stop()
            await move(wasConnected && Self.isTransient(problem) ? .offline(since: Date()) : .failed(problem))
        } catch {
            await master.stop()
            await move(wasConnected ? .offline(since: Date()) : .failed(.installFailed("\(error)")))
        }
    }

    /// Unreachable, timed out, or offline: the network, not the server. Everything else
    /// needs the person.
    static func isTransient(_ problem: HostProblem) -> Bool {
        switch problem {
        case .timedOut, .offline: true
        default: false
        }
    }

    private func run() async throws {
        await move(.connecting(.connect))
        try await master.start(forwardingTo: facts.map { Self.daemonSocket(home: $0.home) })

        await move(.connecting(.checkSystem))
        let probed = try await installer.probe()
        facts = probed
        guard probed.isSupported else {
            throw HostProblem.unsupportedSystem(system: probed.system, architecture: probed.architecture.display)
        }
        guard probed.streamLocalForwarding else { throw HostProblem.noStreamLocalForwarding }
        guard let wanted = await binary(probed.architecture) else {
            throw HostProblem.unsupportedSystem(system: probed.system, architecture: probed.architecture.display)
        }
        if let installed = probed.installedVersion, installed != wanted.version,
           Self.isNewer(installed, than: wanted.version) {
            throw HostProblem.serverNewer(server: installed, app: wanted.version)
        }

        await move(.connecting(.setUp))
        if probed.installedSHA256 != wanted.sha256 {
            try ServerInstaller.checkRoom(probed)
            let first = probed.installedSHA256 == nil
            try await installer.install(binary: wanted.file, sha256: wanted.sha256, firstInstall: first)
            if !first, try await daemonIsBusy() {
                // The new one is in place beside the old; the swap waits for the turn.
                await move(.updateWaiting)
                return
            }
            if !first {
                try? await client.call(DaemonAPI.Method.daemonQuit, DaemonAPI.QuitRequest(stopAgents: false))
                await client.disconnect()
                try await installer.waitForDaemonGone()
            }
            await client.disconnect()
            try await installer.swapCurrent(to: wanted.sha256, version: wanted.version, installedBy: installedBy)
        }

        // The first master had no forward because the home was not known yet.
        try await master.start(forwardingTo: Self.daemonSocket(home: probed.home))
        try await client.connect(timeout: .seconds(20))
        try? await installer.removeBinaries(except: wanted.sha256)

        await move(.connecting(.findRuntimes))
        wasConnected = true
        await master.setOnExit { [weak self] in await self?.lost() }
        await move(.connected)
    }

    /// Whether the running daemon has a turn in flight. A daemon that is not answering
    /// is not busy: there is nothing to wait for.
    private func daemonIsBusy() async throws -> Bool {
        guard let socket = facts.map({ Self.daemonSocket(home: $0.home) }) else { return false }
        try await master.start(forwardingTo: socket)
        guard (try? await client.connect(startIfNeeded: false, timeout: .seconds(3))) != nil else { return false }
        let status = try? await client.call(DaemonAPI.Method.daemonStatus, returning: DaemonAPI.DaemonStatus.self)
        return (status?.turnsInFlight ?? 0) > 0
    }

    public func disconnect() async {
        wasConnected = false
        await client.disconnect()
        await master.stop()
        await move(.idle)
    }

    /// The server's daemon stopped answering while ssh stayed up: it exited, or was
    /// restarted. The same as losing the master, so the window retries, and the retry
    /// starts the daemon again (037).
    public func daemonWentAway() async {
        guard state == .connected else { return }
        await lost()
    }

    private func lost() async {
        await client.disconnect()
        await move(.offline(since: Date()))
    }

    private func move(_ next: State) async {
        state = next
        await onState?(next)
    }

    static func daemonSocket(home: String) -> String {
        (home.hasSuffix("/") ? String(home.dropLast()) : home) + "/.agents-server/root/daemon.sock"
    }

    /// `1.14.0+812` against `1.13.2+790`: the marketing version by its numbers, then the
    /// build. Anything that does not parse is not newer.
    static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ v: String) -> [Int] {
            let halves = v.split(separator: "+", maxSplits: 1)
            let marketing = halves.first.map { $0.split(separator: ".").compactMap { Int($0) } } ?? []
            let build = halves.count > 1 ? Int(halves[1]) ?? 0 : 0
            return marketing + [build]
        }
        let (x, y) = (parts(a), parts(b))
        for i in 0..<max(x.count, y.count) {
            let (p, q) = (i < x.count ? x[i] : 0, i < y.count ? y[i] : 0)
            if p != q { return p > q }
        }
        return false
    }
}
