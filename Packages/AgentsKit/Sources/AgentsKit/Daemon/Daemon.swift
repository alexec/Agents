import ControlDial
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// The daemon, assembled: the lock, the record, the core and the socket.
///
/// `main.swift` is twenty lines because everything here is reachable from `swift test`.
public final class Daemon: @unchecked Sendable {
    public let locations: StoreLocations
    private let lock: DaemonLock
    private let core: DaemonCore
    private var server: DaemonServer?
    /// The control plane this daemon is a host of, if any (058).
    private let control: Control?
    private var uplink: ControlUplink?
    /// What tells the uplink to dial now on a network change (#82).
    private var uplinkTriggers: ReconnectTriggers?
    /// SIGUSR1: Agents Host's *Try Again* on a join that failed (#113).
    private var dialNowSignal: (any DispatchSourceSignal)?

    /// How this host joins its control plane: over a WebSocket, as the control plane
    /// names it, with a host code the first time.
    public struct Control: Sendable {
        public var name: String?
        /// A host code to enrol with, when this root has not yet.
        public var code: String?
        public init(name: String? = nil, code: String? = nil) {
            self.name = name
            self.code = code
        }
    }

    public enum StartError: Error, Sendable {
        /// Another daemon holds the lock. Not a failure: the caller connects to that
        /// one instead.
        case alreadyRunning
    }

    /// Every file the daemon creates is private by default (security review S8). Safe
    /// today because the root is 0700; this keeps scratch roots under `/tmp` the same.
    public static func applyPrivateUmask() {
        _ = umask(0o077)
    }

    public init(locations: StoreLocations = .default,
                discovery: RuntimeDiscovery = RuntimeDiscovery(),
                launcher: (any SessionLauncher)? = nil,
                serve: Bool = false,
                control: Control? = nil,
                toolsetsFolder: URL? = nil,
                sessionLocks: URL? = nil,
                allowOutsideRoot: Bool = true) throws {
        Self.applyPrivateUmask()
        self.locations = locations
        self.control = control
        try locations.createDirectories()
        guard let lock = DaemonLock(at: locations.lock) else { throw StartError.alreadyRunning }
        self.lock = lock
        DaemonLog.shared.setDestination(locations.log)
        WireLog.sink = { DaemonLog.shared.write($0) }
        // The copies of this binary runtimes were once told to start as the MCP helper. The
        // daemon serves the app's tools itself now (#185), so nothing starts them.
        try? FileManager.default.removeItem(at: locations.helpers)
        // Previews an earlier daemon fetched were held only in its memory (#211).
        try? FileManager.default.removeItem(at: locations.catalogStaging)
        Task.detached(priority: .utility) { DiskSweep.runtimeTemporaries(locations) }
        let store = try AgentStore(locations: locations)
        var discovery = discovery
        if serve, discovery.serverHome == nil { discovery.serverHome = ServerSignIn.home }
        // The Mac installs what is missing (048); a server keeps 043's way.
        var installer: (any RuntimeInstalling)?
        #if canImport(Security)
        if !serve {
            if discovery.macToolsHome == nil { discovery.macToolsHome = locations.tools.path }
            #if canImport(CryptoKit)
            let toolsets = toolsetsFolder.map(Toolset.loadAll(from:)) ?? [:]
            let archives = toolsetsFolder.map(ArchiveToolset.loadAll(from:)) ?? [:]
            #else
            // Only a Mac installs its own toolsets, and only a Mac can hash them (043).
            let toolsets: [String: Toolset] = [:]
            let archives: [String: ArchiveToolset] = [:]
            #endif
            discovery.bundledToolsetIDs = toolsets.mapValues(\.id).merging(archives.mapValues(\.id)) { node, _ in node }
            installer = RuntimeInstaller(
                discovery: discovery,
                toolsets: toolsets.mapValues { MacToolsetInstaller(toolset: $0, tools: locations.tools) },
                archives: archives.mapValues { MacArchiveInstaller(toolset: $0, tools: locations.tools) })
        }
        #endif
        // A server's runtimes get their policy's server environment (047: Codex never
        // offers ChatGPT there).
        let launcher = launcher ?? (serve ? ProcessSessionLauncher(locations: locations, onServer: true) : nil)
        self.core = DaemonCore(store: store, locations: locations, discovery: discovery,
                               installer: installer, launcher: launcher)
        self.serve = serve
        self.sessionLocks = sessionLocks
        // A scratch daemon on this Mac runs agents inside its own root (#228). A server's
        // daemon keeps its projects beside its root, never in it, and is exempt.
        self.confinedTo = allowOutsideRoot || serve || locations.isStandard ? nil : locations.root
    }

    /// Where every daemon on this Mac claims the runtime sessions it holds (#228), or nil
    /// for no claims, which is what a test wants.
    private let sessionLocks: URL?
    private let confinedTo: URL?

    /// The folder `agentsd` hands every daemon on this Mac: beside the ordinary root, under
    /// the person's home. `AGENTS_SESSION_LOCKS` names another.
    public static var sharedSessionLocks: URL { SessionClaims.sharedFolder() }

    /// `--allow-outside-root`: a scratch daemon that may run agents anywhere (#228).
    public static let allowOutsideRootFlag = "--allow-outside-root"

    /// Started with `--serve`: a server's daemon, which does not leave for being idle.
    private let serve: Bool

    /// Recover first, then open the door.
    public func start() async throws {
        // Endings are about to be discovered, and no workflow has been read yet. Hold
        // what they raise rather than firing it into a layer that cannot act — see
        // `deferredLifecycleEvents`. `startWorkflows()` below drains it.
        // A host of a control plane is kept running by launchd, not by a window being
        // there, so it never leaves for being idle (058, R5).
        await core.setExitsWhenIdle(!serve && control == nil)
        await core.setHostsForControlPlane(control != nil && !serve)
        await core.holdWorkflowEventsUntilStarted()
        // Before any record is read or any runtime started (#228).
        if let sessionLocks { await core.setSessionLocks(sessionLocks) }
        await core.setConfinedTo(confinedTo)
        if let confinedTo { DaemonLog.shared.write("scratch root: agents run only inside \(confinedTo.path); \(Self.allowOutsideRootFlag) lifts it") }
        // Whatever a previous daemon was cloning when it went is half a repository.
        // It was never in the home folder, so this is the whole of cleaning up (027).
        await core.clearCloneStaging()
        // Before anything is picked up: nothing can be running from an old toolset yet.
        #if canImport(Security)
        (core.installer as? RuntimeInstaller)?.tidy()
        #endif
        // The person's `~/.agents`, laid out before anything is picked up (054).
        await core.reconcileHome()
        // The chat project (#229), after the home it lives in and before recovery, so it
        // is listed before any client asks. A server has no personal home (054 R8), so its
        // chat project goes in its account's `$HOME`, as the server's shell has it.
        if serve, core.locations.personalHome == nil {
            await core.setServerChatHome(URL(fileURLWithPath: ServerSignIn.home, isDirectory: true))
        }
        await core.ensureChatProject()
        // An add the last daemon died in the middle of is undone before anyone looks (059).
        #if canImport(CryptoKit)
        await core.recoverCatalog()
        #endif
        // Off the start: it runs Codex's own command, which takes a moment (054, R12).
        Task { await core.syncCodexPlugins() }
        let recovered = await core.recover()
        if !recovered.isEmpty {
            DaemonLog.shared.write("marked \(recovered.count) agent(s) stopped: their processes were gone")
        }
        let core = self.core
        // Who may ask for what on the socket, from the caller's code signature.
        let roles = RolePolicy.forDaemon(at: locations)
        DaemonLog.shared.write("socket: \(roles.summary)")
        let server = DaemonServer(
            url: locations.socket,
            onConnectionCountChanged: { count in
                Task { await core.setConnectionCount(count) }
            },
            onDisconnected: { connection in
                Task {
                    await core.forgetPresence(connection: connection)
                    // A start form's runtime, left behind by a phone that went away.
                    // Let go after a grace period rather than now, so one that only
                    // dropped for a moment still finds it (029).
                    await core.orphanDrafts(connection: connection)
                    // A bridge that has gone carries nothing. Left on the list, the next
                    // withdrawal would be handed to nobody and forgotten (025 US2).
                    await core.forgetCarrier(connection: connection)
                    // What it was watching and which shells it had open (034).
                    await core.connectionEnded(connection)
                }
            },
            roles: roles,
            handler: { context, method, params in
                await core.handle(method: method, params: params,
                                  from: context.surface, connection: context.id, peer: context.peer ?? -1,
                                  role: context.role, vouched: context.vouched)
            })
        self.server = server
        await core.setBroadcaster { method, params in
            server.broadcast(method, params)
        }
        await core.setAddressedBroadcaster { method, params, wanted in
            server.broadcast(method, params, to: wanted)
        }
        await core.setConnectionCloser { wanted in
            server.closeConnections(where: wanted)
        }
        // Shell output goes out the same door as every other notification.
        await core.connectShells()
        // Read every project's workflows, watch their folders, start the clock. After
        // recovery, so a workflow is never fired at an agent the daemon has not yet
        // worked out is dead.
        await core.startWorkflows()
        // Servers' events (#383), once the workflows that name them are read. Off the
        // start: asking each server what it offers can take a while, and the socket
        // must not wait on it.
        await core.startHostedServers()
        Task { await core.startMCPEvents() }
        try server.start()
        DaemonLog.shared.write("listening on \(locations.socket.path)")
        if let control {
            let name = control.name ?? Host.current().localizedName ?? "A Mac"
            let hello = DaemonAPI.HostHello(host: .mac, version: Self.version, platform: Self.platform,
                                            machineID: MachineID.current, name: name)
            await join(control, server: server, hello: hello)
        }
        // Last, and on purpose. Picking an agent back up starts a runtime and sends it
        // a prompt, and both of those belong in front of a window that can watch them
        // rather than behind a socket nobody can reach yet.
        await core.pickUpAfterRestart(recovered)
        // After the pick-ups are known, so a wait on a chat coming back stays open (039).
        await core.resumeBlocksAfterRestart()
        // And the waits on events (042): a wake queued and never sent goes now, and a
        // deadline that passed while nothing ran ends now.
        await core.resumeEventWaitsAfterRestart()
        // Helpers queued before the restart (#362), behind the ones coming back.
        await core.checkEveryQueue()
        // The Mac and the person, as events (042). Only in the real daemon; a test
        // hands the core a fake.
        await core.startWatchingMachine()
        // And the volumes it writes to (#195).
        await core.startWatchingDisk()
        // Last of all, once the agents that are coming back are back. A daemon
        // restarting under resumed agents is holding work from its first moment, and
        // without this it would not take the assertion until one of them next changed
        // state — which for a long turn could be half an hour (024 FR-014).
        await core.reviseWakefulness()
    }

    /// A sign-in relayed between hosts through the control plane (058, T091): this Mac's
    /// relays are what a tunnel to it reaches, and a server's gate opens a tunnel from it.
    private func lendAndBorrowSignIns(through uplink: ControlUplink) async {
        let core = self.core
        uplink.setLendingPort { runtime in await core.signInRelayPort(runtime) }
        await core.setTunnelOpener { runtime in try await uplink.openTunnel(runtime: runtime) }
    }

    /// A host of a control plane (058, T021): enrolled once with a version 2 host code,
    /// given or left in the root by Agents Host, then dialled over the WebSocket with its
    /// own key, on a Mac and on Linux alike.
    private func join(_ control: Control, server: DaemonServer, hello: DaemonAPI.HostHello) async {
        let kept = ControlMembership.load(locations.controlHostMembership)
        if let kept, kept.url == nil {
            // The first build's TLS-PSK membership: that wire is gone (T042). Said, so the
            // window can tell a live host that cannot enrol from one that is not running.
            let problem = "this host's membership is from before the control plane's WebSocket; open Agents Host and press Try Again"
            DaemonLog.shared.write("uplink: \(problem)")
            sayJoin(.init(member: false, connected: false, problem: problem))
            return
        }
        if kept == nil, let code = (control.code ?? readLeftCode()).flatMap(ControlCode.init(text:)), code.url == nil {
            let problem = "that host code is from before the control plane's WebSocket; ask Agents Host for a new one"
            DaemonLog.shared.write("uplink: \(problem)")
            sayJoin(.init(member: false, connected: false, problem: problem))
            return
        }
        // No code yet still dials (#303). Returning here left `control-join.json` unwritten
        // and ignored Agents Host's Try Again, which leaves a code and then signals. The
        // dial says there is no host code, keeps trying, and reads a code left later.
        await joinOverWebSocket(given: control.code, server: server, hello: hello)
    }

    /// A code Agents Host left in the root. Kept until a join has saved a membership, so a
    /// first dial that fails tries again with it (#113).
    private func readLeftCode() -> String? {
        guard let text = try? String(contentsOf: locations.controlJoinCode, encoding: .utf8) else { return nil }
        let code = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return code.isEmpty ? nil : code
    }

    /// How the join stands, for Agents Host and the control plane beside it (#113).
    private func sayJoin(_ status: DaemonAPI.HostJoinStatus) {
        HostJoinFile(pid: getpid(), status: status).write(to: locations.controlJoinStatus)
    }

    /// Dials as this host with its own key, kept beside the membership in this root,
    /// enrolling first with the host code while there is no membership yet. Both are one
    /// dial of the uplink, so a first join that fails is tried again on the same backoff,
    /// and at once on a wake or a network change, as a dial after it has joined is (#113).
    private func joinOverWebSocket(given: String?, server: DaemonServer, hello: DaemonAPI.HostHello) async {
        let membershipFile = locations.controlHostMembership
        let privateKey: Data
        do {
            privateKey = try ControlAgreement.loadOrMake(file: locations.controlHostKey)
        } catch {
            DaemonLog.shared.write("uplink: could not join the control plane: this host's key: \(error)")
            sayJoin(.init(member: false, connected: false, problem: "this host's key: \(error)"))
            return
        }
        let dialer = HostDialer(membershipFile: membershipFile, codeFile: locations.controlJoinCode, given: given,
                                privateKey: privateKey, hello: hello, say: { [weak self] in self?.sayJoin($0) })
        let uplink = ControlUplink(server: server, hello: hello,
                                   onChange: { [dialer, core] up in
                                       dialer.connected(up)
                                       Task { await core.controlUplinkChanged(up) }
                                   },
                                   dial: { [dialer] in try await dialer.dial() })
        self.uplink = uplink
        await core.deliverNeeds { [uplink] params in uplink.tell(DaemonAPI.Method.attentionNeed, params) }
        await lendAndBorrowSignIns(through: uplink)
        uplink.setProjectDetector { [core] detection in await core.detectProjects(detection) }
        uplink.start()
        let nudge: @Sendable (ReconnectTriggers.Reason) -> Void = { [uplink] reason in
            let nudged = uplink.goBackNow()
            if nudged != .idle { DaemonLog.shared.write("uplink: \(reason.rawValue): dialling now (\(nudged))") }
        }
        let queue = DispatchQueue(label: "uplink.triggers")
        let triggers = ReconnectTriggers(queue: queue, onTrigger: nudge)
        uplinkTriggers = triggers
        triggers.start()
        // SIGUSR1: Agents Host's Try Again (#113), as the control plane's is for its page.
        signal(SIGUSR1, SIG_IGN)
        let asked = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: queue)
        asked.setEventHandler { [uplink] in
            DaemonLog.shared.write("uplink: asked to try again: dialling now (\(uplink.goBackNow()))")
        }
        asked.resume()
        dialNowSignal = asked
        // A wake, heard by the machine watch: `agentsd` has no AppKit to hear it from.
        await core.onWake { nudge(.wake) }
        if let membership = ControlMembership.load(membershipFile) {
            DaemonLog.shared.write("uplink: a host of \(membership.name) at \(membership.url ?? "?"), as \(membership.host?.rawValue ?? "?")")
        }
    }

    /// Serve until there is nothing in hand and nobody connected.
    public func run(grace: Duration = .seconds(10)) async {
        await core.runUntilIdle(grace: grace)
        await shutDown()
    }

    public func shutDown() async {
        DaemonLog.shared.write("shutting down")
        uplinkTriggers?.stop()
        dialNowSignal?.cancel()
        uplink?.stop()
        server?.stop()
        await core.shutDown()
        lock.release()
    }

    public static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    public static var platform: String {
        #if os(macOS)
        let os = "macOS"
        #else
        let os = "Linux"
        #endif
        #if arch(arm64)
        return os + " arm64"
        #else
        return os + " x86-64"
        #endif
    }

    /// For tests, which drive the core directly rather than over a socket.
    public var daemonCore: DaemonCore { core }
}
