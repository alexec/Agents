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
        case connect, checkSystem, setUp, installClaude, findRuntimes
    }

    /// Claude's toolset on this server (043). Apart from `state`, because none of it makes
    /// the server unusable: a failed install leaves its files, terminal and other runtimes.
    public enum Claude: Sendable, Equatable {
        /// Not looked at yet, or the app carries no toolset.
        case unknown
        /// Nothing installed, and nothing asked for it yet (FR-002).
        case notInstalled
        case installing
        /// The app's toolset, this id.
        case ready(String)
        /// The person's own install (037's npx on their PATH), used as it is (FR-005).
        case own
        case failed(HostProblem)
        /// A newer toolset is installed beside the old; it takes over once no turn is in flight.
        case updateWaiting
    }

    public nonisolated let hostID: HostID
    public nonisolated let client: DaemonClient
    public private(set) var state: State = .idle
    public private(set) var facts: ServerFacts?
    /// How each runtime the app installs stands on this server (043 for Claude, 046 for the
    /// rest), by runtime id. `Claude` is the state's name for history's sake.
    public private(set) var toolsetStates: [String: Claude] = [:]
    public var claude: Claude { state(of: RuntimeCatalog.claude.id) }
    public func state(of runtimeID: String) -> Claude { toolsetStates[runtimeID] ?? .unknown }

    private nonisolated let master: SSHMaster
    private let installer: ServerInstaller
    private let binary: @Sendable (Architecture) async -> ServerBinary?
    private let installedBy: String
    private let tools: ToolsetInstaller
    private let toolset: @Sendable () -> Toolset?
    private let otherToolsets: @Sendable () -> [Toolset]
    private let wantsClaude: @Sendable () async -> Bool
    private let wantsOther: @Sendable (String) async -> Bool
    private let offer: @Sendable () async -> DaemonAPI.CredentialsOffer?
    private let lender: DaemonClient.CredentialLender?
    private let relay: @Sendable () async -> [RelayGrant]
    private var onState: (@Sendable (State) async -> Void)?
    private var onClaude: (@Sendable (Claude) async -> Void)?
    private var onToolset: (@Sendable (String, Claude) async -> Void)?
    private var wasConnected = false
    private var isConnecting = false

    /// - Parameters:
    ///   - ssh: the host's command, its control path under `<root>/hosts/`.
    ///   - socket: the forward's local end, `<root>/hosts/<id>.sock`.
    ///   - binary: what to install on a server of this architecture; nil when the app
    ///     has none for it.
    ///   - toolset: Claude's toolset, to install when `wantsClaude` says so (043); nil
    ///     when the app carries none.
    ///   - wantsClaude: whether to install Claude as the server connects: the window has a
    ///     credential for it (FR-002). Otherwise it waits for `installClaude()`.
    ///   - otherToolsets, wants: the same for every other runtime the app installs (046:
    ///     Gemini), each installed as the server connects when `wants` says so for its id.
    public init(hostID: HostID, ssh: SSHCommand, socket: URL, installedBy: String,
                binary: @escaping @Sendable (Architecture) async -> ServerBinary?,
                toolset: @escaping @Sendable () -> Toolset? = { nil },
                wantsClaude: @escaping @Sendable () async -> Bool = { false },
                otherToolsets: @escaping @Sendable () -> [Toolset] = { [] },
                wants: @escaping @Sendable (String) async -> Bool = { _ in false },
                offer: @escaping @Sendable () async -> DaemonAPI.CredentialsOffer? = { nil },
                lender: DaemonClient.CredentialLender? = nil,
                relay: @escaping @Sendable () async -> [RelayGrant] = { [] }) {
        self.relay = relay
        self.offer = offer
        self.lender = lender
        self.hostID = hostID
        let master = SSHMaster(command: ssh, socket: socket)
        let installer = ServerInstaller(ssh: ssh)
        self.master = master
        self.installer = installer
        self.tools = ToolsetInstaller(ssh: ssh)
        self.toolset = toolset
        self.otherToolsets = otherToolsets
        self.wantsClaude = wantsClaude
        self.wantsOther = wants
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

    public func setOnClaude(_ handler: @escaping @Sendable (Claude) async -> Void) {
        onClaude = handler
    }

    /// Every runtime's toolset moving, Claude's included (046).
    public func setOnToolset(_ handler: @escaping @Sendable (String, Claude) async -> Void) {
        onToolset = handler
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
            if !first, await reachRunningDaemon() {
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
        await offerCredentials()
        await offerRelay(home: probed.home)

        await settleToolsets(probed)

        await move(.connecting(.findRuntimes))
        wasConnected = true
        await master.setOnExit { [weak self] in await self?.lost() }
        await move(.connected)
    }

    // MARK: Credentials (043)

    /// Tell the server's daemon what this window could lend, on every connect: a lend
    /// lasts only as long as the connection it was made on. Names only.
    public func offerCredentials() async {
        await client.setCredentialLender(lender)
        guard let offer = await offer() else { return }
        _ = try? await client.call(DaemonAPI.Method.credentialsOffer, offer)
    }

    /// What a window relays to its servers (047): a runtime's sign-in, served on this Mac at
    /// `localPort`, with the CA certificate to trust and the stand-in the runtime starts with.
    public struct RelayGrant: Sendable {
        public var runtime: String
        public var localPort: UInt16
        public var caCertificate: String
        public var standIn: String

        public init(runtime: String, localPort: UInt16, caCertificate: String, standIn: String) {
            self.runtime = runtime
            self.localPort = localPort
            self.caCertificate = caCertificate
            self.standIn = standIn
        }
    }

    /// The server end of the relay's forward, in the server's own folder.
    static func relaySocket(home: String, runtime: String) -> String {
        "\(home)/.agents-server/relay-\(runtime).sock"
    }

    /// On every connect: for each sign-in this window relays (047 Codex, 056 Claude), forward
    /// a socket on the server back to it and tell the server's daemon, which opens its gate.
    /// Never throws: without a relay the server still works, and says what sign-in it needs.
    public func offerRelay(home: String) async {
        for grant in await relay() { await offerRelay(grant, home: home) }
    }

    private func offerRelay(_ grant: RelayGrant, home: String) async {
        let socket = Self.relaySocket(home: home, runtime: grant.runtime)
        // A socket a previous master left in place would make the forward fail.
        _ = try? await master.command.run(master.command.runArguments("rm -f '\(socket)'"))
        let forwarded = try? await master.command.run(
            master.command.remoteForwardArguments(remote: socket, local: "127.0.0.1:\(grant.localPort)"))
        guard forwarded?.status == 0 else {
            DaemonLog.shared.write("relay: forwarding \(socket) failed: \(forwarded?.stderr ?? "no answer")")
            return
        }
        _ = try? await client.call(DaemonAPI.Method.relayOffer,
                                   DaemonAPI.RelayOffer(runtime: grant.runtime, socketPath: socket,
                                                        caCertificate: grant.caCertificate, standIn: grant.standIn))
    }

    /// Lend a credential on this connection. Only after the daemon asked for it.
    public func lend(_ runtimeID: String, _ secret: Secret) async -> Bool {
        (try? await client.call(DaemonAPI.Method.credentialsLend,
                                DaemonAPI.CredentialsLend(runtime: runtimeID, secret: secret))) != nil
    }

    // MARK: The app's toolsets (043 Claude, 046 the rest)

    /// Claude's first, then the others in the order the app carries them.
    private var allToolsets: [Toolset] {
        (toolset().map { [$0] } ?? []) + otherToolsets().filter { $0.manifest.runtimeID != RuntimeCatalog.claude.id }
    }

    private func wants(_ runtimeID: String) async -> Bool {
        runtimeID == RuntimeCatalog.claude.id ? await wantsClaude() : await wantsOther(runtimeID)
    }

    /// On connect: say how each toolset stands, and install or update it when the window
    /// has a credential for it. Never throws: the server is usable either way.
    private func settleToolsets(_ probed: ServerFacts) async {
        if toolset() == nil { await moveToolset(RuntimeCatalog.claude.id, .unknown) }
        for toolset in allToolsets { await settle(toolset, probed) }
    }

    private func settle(_ toolset: Toolset, _ probed: ServerFacts) async {
        let runtimeID = toolset.manifest.runtimeID
        let installed = probed.toolsetID(for: runtimeID) ?? (runtimeID == RuntimeCatalog.claude.id ? probed.toolsetID : nil)
        if installed == toolset.id {
            // Old toolsets go only when nothing could still be running from one: an agent
            // idle between turns keeps its process, and that process its files.
            if await agentsLive() == 0 { try? await tools.removeOthers(except: toolset.id, runtimeID: runtimeID) }
            return await moveToolset(runtimeID, .ready(toolset.id))
        }
        // The person's own npx is Claude's own way (037); a runtime that runs only the app's
        // copy has none.
        let usesOwn = !(RuntimeCatalog.runtime(id: runtimeID)?.usesAppCopyOnly ?? true) && toolset.shimName == "npx"
        if installed == nil, usesOwn, probed.hasNpx { return await moveToolset(runtimeID, .own) }
        let wanted = await wants(runtimeID)
        guard installed != nil || wanted else { return await moveToolset(runtimeID, .notInstalled) }
        await move(.connecting(.installClaude))
        await install(toolset, on: probed, installed: installed)
    }

    /// Install Claude now: the person chose it on this server, or asked to try again.
    /// Waits for the install, and says how it went in `claude`.
    public func installClaude() async {
        await install(runtimeID: RuntimeCatalog.claude.id)
    }

    /// Install a runtime's toolset now (046). Says how it went in `state(of:)`.
    public func install(runtimeID: String) async {
        guard let toolset = allToolsets.first(where: { $0.manifest.runtimeID == runtimeID }),
              let facts, state == .connected || state == .updateWaiting else { return }
        await install(toolset, on: facts, installed: facts.toolsetID(for: runtimeID))
    }

    private func install(_ toolset: Toolset, on facts: ServerFacts, installed: String?) async {
        let runtimeID = toolset.manifest.runtimeID
        await moveToolset(runtimeID, .installing)
        do {
            // An update already downloaded and waiting for a turn to end is not fetched again.
            if !(await tools.isInstalled(toolset.id, runtimeID: runtimeID)) {
                try await tools.install(toolset, on: facts)
            }
            // Replacing one in use waits for its turns to end (FR-007): what is running
            // keeps its files; the swap is tried again on the next connect.
            if installed != nil, (try? await daemonIsBusy()) == true {
                return await moveToolset(runtimeID, .updateWaiting)
            }
            try await tools.swap(to: toolset.id, runtimeID: runtimeID)
            // A first install has nothing to tidy; an update's old toolset is removed on a
            // later connect with no agent live (see `settle`).
            self.facts?.toolsetIDs[runtimeID] = toolset.id
            if runtimeID == RuntimeCatalog.claude.id { self.facts?.toolsetID = toolset.id }
            await moveToolset(runtimeID, .ready(toolset.id))
        } catch let problem as HostProblem {
            await moveToolset(runtimeID, .failed(problem))
        } catch {
            await moveToolset(runtimeID, .failed(.toolsetInstallFailed("\(error)")))
        }
    }

    private func moveToolset(_ runtimeID: String, _ next: Claude) async {
        toolsetStates[runtimeID] = next
        if runtimeID == RuntimeCatalog.claude.id { await onClaude?(next) }
        await onToolset?(runtimeID, next)
    }

    /// Whether the running daemon has a turn in flight. A daemon that is not answering
    /// is not busy: there is nothing to wait for.
    private func daemonIsBusy() async throws -> Bool {
        guard let socket = facts.map({ Self.daemonSocket(home: $0.home) }) else { return false }
        try await master.start(forwardingTo: socket)
        guard await reachRunningDaemon() else { return false }
        let status = try? await client.call(DaemonAPI.Method.daemonStatus, returning: DaemonAPI.DaemonStatus.self)
        return (status?.turnsInFlight ?? 0) > 0
    }

    /// Connect to a daemon that may be running, without starting one. The forward's
    /// local end can appear a moment after the master answers, so one miss is not taken
    /// for no daemon: a few tries, then no.
    private func reachRunningDaemon(within wait: Duration = .seconds(3)) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: wait)
        repeat {
            if (try? await client.connect(startIfNeeded: false)) != nil { return true }
            try? await Task.sleep(for: .milliseconds(100))
        } while ContinuousClock.now < deadline
        return false
    }

    /// How many agents removing this server would stop (037, the Remove dialog).
    public func agentsLive() async -> Int {
        let status = try? await client.call(DaemonAPI.Method.daemonStatus, returning: DaemonAPI.DaemonStatus.self)
        return status?.agentsLive ?? 0
    }

    /// Remove the server (037 US5): its agents are stopped and its daemon quits; with
    /// `purge`, what Agents installed goes too. The person's folders are never touched:
    /// they are not under `~/.agents-server`.
    public func remove(purge: Bool) async throws {
        if state == .connected {
            _ = try? await client.call(DaemonAPI.Method.daemonQuit, DaemonAPI.QuitRequest(stopAgents: true))
            await client.disconnect()
            try? await installer.waitForDaemonGone()
        }
        if purge {
            if !(await master.isRunning) { try await master.start(forwardingTo: nil) }
            try await installer.purge()
        }
        await disconnect()
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
