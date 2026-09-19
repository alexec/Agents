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
                launcher: (any SessionLauncher)? = nil) throws {
        self.locations = locations
        try locations.createDirectories()
        guard let lock = DaemonLock(at: locations.lock) else { throw StartError.alreadyRunning }
        self.lock = lock
        DaemonLog.shared.setDestination(locations.log)
        let store = try AgentStore(locations: locations)
        self.core = DaemonCore(store: store, locations: locations, discovery: discovery, launcher: launcher)
    }

    /// Recover first, then open the door.
    public func start() async throws {
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
            handler: { method, params in
                await core.handle(method: method, params: params)
            })
        self.server = server
        await core.setBroadcaster { method, params in
            server.broadcast(method, params)
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
