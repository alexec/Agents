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
                toolsetsFolder: URL? = nil) throws {
        Self.applyPrivateUmask()
        self.locations = locations
        self.control = control
        try locations.createDirectories()
        guard let lock = DaemonLock(at: locations.lock) else { throw StartError.alreadyRunning }
        self.lock = lock
        DaemonLog.shared.setDestination(locations.log)
        // Before any runtime starts, so every helper is started from the copy.
        if let own = DaemonCore.ownExecutable,
           let pinned = PinnedHelper.pin(own, in: locations.helpers) {
            DaemonCore.pinnedHelper.path = pinned.path
            DaemonLog.shared.write("helper: runtimes start \(pinned.path)")
        }
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
    }

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
        // Whatever a previous daemon was cloning when it went is half a repository.
        // It was never in the home folder, so this is the whole of cleaning up (027).
        await core.clearCloneStaging()
        // Before anything is picked up: nothing can be running from an old toolset yet.
        #if canImport(Security)
        (core.installer as? RuntimeInstaller)?.tidy()
        #endif
        // The person's `~/.agents`, laid out before anything is picked up (054).
        await core.reconcileHome()
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
                                  role: context.role)
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
        // The Mac and the person, as events (042). Only in the real daemon; a test
        // hands the core a fake.
        await core.startWatchingMachine()
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
            // The first build's TLS-PSK membership: that wire is gone (T042).
            DaemonLog.shared.write("uplink: this host's membership is from before the control plane's WebSocket; enrol it again with a new host code")
            return
        }
        let code = (control.code ?? takeLeftCode()).flatMap(ControlCode.init(text:))
        if kept == nil, let code, code.url == nil {
            DaemonLog.shared.write("uplink: that host code is from before the control plane's WebSocket; ask for a new one")
            return
        }
        await joinOverWebSocket(code: kept == nil ? code : nil, server: server, hello: hello)
    }

    /// A code Agents Host left in the root, taken once: it is spent by the first join.
    private func takeLeftCode() -> String? {
        let file = locations.controlJoinCode
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        try? FileManager.default.removeItem(at: file)
        let code = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return code.isEmpty ? nil : code
    }

    /// Enrols with a version 2 host code if there is no membership yet, then dials as this
    /// host with its own key, kept beside the membership in this root.
    private func joinOverWebSocket(code: ControlCode?, server: DaemonServer, hello: DaemonAPI.HostHello) async {
        let membershipFile = locations.controlHostMembership
        do {
            let privateKey = try ControlAgreement.loadOrMake(file: locations.controlHostKey)
            var membership = ControlMembership.load(membershipFile)
            if membership == nil, let code {
                let joined = try await ControlJoin.enrollHost(code, privateKey: privateKey, hello: hello)
                try joined.save(membershipFile)
                membership = joined
                DaemonLog.shared.write("uplink: enrolled with \(joined.name) as \(joined.host?.rawValue ?? "?")")
            }
            guard let membership else {
                DaemonLog.shared.write("uplink: no control plane to join; start with --control <code>")
                return
            }
            let uplink = ControlUplink(server: server, hello: hello,
                                       dial: try ControlJoin.hostDial(membership, privateKey: privateKey))
            self.uplink = uplink
            await core.deliverNeeds { [uplink] params in uplink.tell(DaemonAPI.Method.attentionNeed, params) }
            await lendAndBorrowSignIns(through: uplink)
            uplink.start()
            DaemonLog.shared.write("uplink: a host of \(membership.name) at \(membership.url ?? "?"), as \(membership.host?.rawValue ?? "?")")
        } catch {
            DaemonLog.shared.write("uplink: could not join the control plane: \(error)")
        }
    }

    /// Serve until there is nothing in hand and nobody connected.
    public func run(grace: Duration = .seconds(10)) async {
        await core.runUntilIdle(grace: grace)
        await shutDown()
    }

    public func shutDown() async {
        DaemonLog.shared.write("shutting down")
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
