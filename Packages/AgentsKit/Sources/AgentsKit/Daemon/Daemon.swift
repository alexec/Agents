import Foundation

/// The daemon, assembled: the lock, the record, the core and the socket.
///
/// `main.swift` is twenty lines because everything here is reachable from `swift test`.
public final class Daemon: @unchecked Sendable {
    public let locations: StoreLocations
    private let lock: DaemonLock
    private let core: DaemonCore
    private var server: DaemonServer?

    public enum StartError: Error, Sendable {
        /// Another daemon holds the lock. Not a failure: the caller connects to that
        /// one instead.
        case alreadyRunning
    }

    public init(locations: StoreLocations = .default,
                discovery: RuntimeDiscovery = RuntimeDiscovery(),
                launcher: (any SessionLauncher)? = nil,
                serve: Bool = false) throws {
        self.locations = locations
        try locations.createDirectories()
        guard let lock = DaemonLock(at: locations.lock) else { throw StartError.alreadyRunning }
        self.lock = lock
        DaemonLog.shared.setDestination(locations.log)
        let store = try AgentStore(locations: locations)
        self.core = DaemonCore(store: store, locations: locations, discovery: discovery, launcher: launcher)
        self.serve = serve
    }

    /// Started with `--serve`: a server's daemon, which does not leave for being idle.
    private let serve: Bool

    /// Recover first, then open the door.
    public func start() async throws {
        // Endings are about to be discovered, and no workflow has been read yet. Hold
        // what they raise rather than firing it into a layer that cannot act — see
        // `deferredLifecycleEvents`. `startWorkflows()` below drains it.
        await core.setExitsWhenIdle(!serve)
        await core.holdWorkflowEventsUntilStarted()
        // Whatever a previous daemon was cloning when it went is half a repository.
        // It was never in the home folder, so this is the whole of cleaning up (027).
        await core.clearCloneStaging()
        let recovered = await core.recover()
        if !recovered.isEmpty {
            DaemonLog.shared.write("marked \(recovered.count) agent(s) stopped: their processes were gone")
        }
        let core = self.core
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
            handler: { context, method, params in
                await core.handle(method: method, params: params,
                                  from: context.surface, connection: context.id)
            })
        self.server = server
        await core.setBroadcaster { method, params in
            server.broadcast(method, params)
        }
        await core.setAddressedBroadcaster { method, params, wanted in
            server.broadcast(method, params, to: wanted)
        }
        // Shell output goes out the same door as every other notification.
        await core.connectShells()
        // Read every project's workflows, watch their folders, start the clock. After
        // recovery, so a workflow is never fired at an agent the daemon has not yet
        // worked out is dead.
        await core.startWorkflows()
        try server.start()
        DaemonLog.shared.write("listening on \(locations.socket.path)")
        // Last, and on purpose. Picking an agent back up starts a runtime and sends it
        // a prompt, and both of those belong in front of a window that can watch them
        // rather than behind a socket nobody can reach yet.
        await core.pickUpAfterRestart(recovered)
        // After the pick-ups are known, so a wait on a chat coming back stays open (039).
        await core.resumeBlocksAfterRestart()
        // Last of all, once the agents that are coming back are back. A daemon
        // restarting under resumed agents is holding work from its first moment, and
        // without this it would not take the assertion until one of them next changed
        // state — which for a long turn could be half an hour (024 FR-014).
        await core.reviseWakefulness()
    }

    /// Serve until there is nothing in hand and nobody connected.
    public func run(grace: Duration = .seconds(10)) async {
        await core.runUntilIdle(grace: grace)
        await shutDown()
    }

    public func shutDown() async {
        DaemonLog.shared.write("shutting down")
        server?.stop()
        await core.shutDown()
        lock.release()
    }

    /// For tests, which drive the core directly rather than over a socket.
    public var daemonCore: DaemonCore { core }
}
