import Foundation

public enum DaemonServerError: Error, Sendable {
    case socketPathTooLong(Int)
    case cannotCreateSocket(errno: Int32)
    case cannotBind(errno: Int32)
    case cannotListen(errno: Int32)
}

/// The daemon's front door: a Unix socket, and a JSON-RPC connection per window.
///
/// Several connections at once are normal, and all of them get every notification, so
/// two windows agree without either of them being in charge.
public final class DaemonServer: @unchecked Sendable {
    /// Who a request came from. `surface` is the identity presence is reported under —
    /// a window is `.mac`; a connection the bridge opens on behalf of a device is that
    /// device (Slice C) — and it is set by the server, never said by the caller (021).
    public struct ConnectionContext: Hashable, Sendable {
        public var id: UUID
        public var surface: Surface?

        public init(id: UUID, surface: Surface?) {
            self.id = id
            self.surface = surface
        }
    }

    public typealias Handler = @Sendable (ConnectionContext, String, JSONValue?) async -> Result<JSONValue, JSONRPCError>

    /// One connection's identity, held by the server for the connection's life. It
    /// starts as a window and becomes a device only through `surface/identify`, which
    /// the server reads before the request reaches the daemon — so the daemon never
    /// sees a surface a caller merely claimed in some other request's parameters.
    final class ConnectionIdentity: @unchecked Sendable {
        let id = UUID()
        private let lock = NSLock()
        private var _surface: Surface? = .mac

        var surface: Surface? {
            get { lock.lock(); defer { lock.unlock() }; return _surface }
            set { lock.lock(); defer { lock.unlock() }; _surface = newValue }
        }

        var context: ConnectionContext { ConnectionContext(id: id, surface: surface) }
    }

    private let url: URL
    private let handler: Handler
    /// Readable inside the module so a test can ask whether it would survive an exec.
    /// There is no other way to see the flag: it only shows itself in a child.
    private(set) var listenFD: Int32 = -1
    private let connections = ConnectionSet()
    private let stopped = ManagedAtomicFlag()
    private let onConnectionCountChanged: @Sendable (Int) -> Void
    /// A connection that has gone, by id. What is known about where its person was
    /// goes with it: gone is more truthful than stale (021).
    private let onDisconnected: @Sendable (UUID) -> Void

    public init(url: URL,
                onConnectionCountChanged: @escaping @Sendable (Int) -> Void = { _ in },
                onDisconnected: @escaping @Sendable (UUID) -> Void = { _ in },
                handler: @escaping Handler) {
        self.url = url
        self.handler = handler
        self.onConnectionCountChanged = onConnectionCountChanged
        self.onDisconnected = onDisconnected
    }

    public func start() throws {
        // sockaddr_un has room for 104 bytes and not one more, which is easy to exceed
        // with a temporary directory and worth saying plainly rather than truncating.
        let path = url.path
        guard path.utf8.count < 104 else { throw DaemonServerError.socketPathTooLong(path.utf8.count) }

        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        unlink(path)

        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else { throw DaemonServerError.cannotCreateSocket(errno: errno) }
        // The front door belongs to this process. A child holding a copy of it keeps
        // the socket answering after the daemon has gone, so the window connects to
        // nobody and waits for a reply that is never coming. Darwin has no
        // SOCK_CLOEXEC, so it is asked for the moment there is something to ask about.
        setCloseOnExec(listenFD)

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            path.withCString { source in
                strncpy(UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: CChar.self), source, 103)
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listenFD, $0, size) }
        }
        guard bound == 0 else {
            close(listenFD)
            throw DaemonServerError.cannotBind(errno: errno)
        }
        guard listen(listenFD, 16) == 0 else {
            close(listenFD)
            throw DaemonServerError.cannotListen(errno: errno)
        }

        let listenFD = self.listenFD
        let thread = Thread { [weak self] in
            while true {
                let fd = accept(listenFD, nil, nil)
                if fd < 0 {
                    if errno == EINTR { continue }
                    return
                }
                // accept() hands back a descriptor with the flag clear however the
                // listener was opened, so each window's connection says it again.
                // This is the one a long-lived shell is most likely to be handed: a
                // window connects, an agent starts a terminal, and the window's
                // connection is held open by a shell that will never read it.
                setCloseOnExec(fd)
                DaemonServer.limitSendWait(fd)
                guard let self, !self.stopped.isSet else { close(fd); return }
                self.accepted(fd)
            }
        }
        thread.name = "AgentsKit.DaemonServer"
        thread.start()
    }

    private func accepted(_ fd: Int32) {
        let transport = FDTransport(socket: fd)
        // Everything that reaches this socket is a window on this Mac, until the bridge
        // exists to say otherwise: helpers and probes that connect here never report
        // presence, and a window that does is the Mac.
        let identity = ConnectionIdentity()
        let handler = self.handler
        let connection = JSONRPCConnection(transport: transport) { method, params in
            // A device saying which it is. The server sets the identity here, once,
            // and only then hands the request on — so what the daemon registers under
            // is what every later request on this connection will carry (021 T051).
            if method == DaemonAPI.Method.surfaceIdentify,
               let who = try? params?.decode(DaemonAPI.SurfaceIdentification.self) {
                identity.surface = .device(who.id)
            }
            return await handler(identity.context, method, params)
        }
        connections.add(connection, queue: DispatchQueue(label: "com.alexecollins.agents.broadcast.\(identity.id)"),
                        identity: identity)
        onConnectionCountChanged(connections.count)
        Task {
            await connection.start()
            // The connection ends when the window goes. Which it will: quitting the
            // app is the ordinary case, not the exceptional one.
            for await _ in connection.incomingNotifications() {}
            // The stream ending says the other side hung up; it does not close our
            // descriptor, and nothing else will. Left open, every window, phone and
            // helper that ever connected costs the daemon one descriptor for the rest
            // of its life, until `accept` fails and the front door is shut with the
            // daemon still standing behind it — 2,422 of them, one Sunday morning.
            await connection.close()
            self.connections.remove(connection)
            self.onConnectionCountChanged(self.connections.count)
            self.onDisconnected(identity.id)
        }
    }

    /// Tell every window at once.
    ///
    /// On one queue of its own, rather than a task per notification. A task each put
    /// the order in the runtime's hands, and two chunks of a shell's output that
    /// arrive the wrong way round are not slow, they are wrong; one serial queue keeps
    /// them in the order the daemon said them. It is a queue rather than a plain call
    /// because this is reached from inside the actor that owns every agent, and
    /// writing to a socket blocks until the window on the other end reads. A window
    /// that has stopped reading should cost the windows their news, not the daemon its
    /// agents.
    ///
    /// One queue **per connection**, not one for them all. With one, a window that
    /// stopped reading blocked the queue on its write, and every other window and the
    /// bridge stopped hearing anything while the backlog grew without bound. Each
    /// connection's own queue keeps its own order, which is the only order that
    /// matters; and a write that cannot finish in `sendWait` fails, the connection is
    /// closed, and the client reconnects and asks for everything again — which a
    /// window already does whenever its connection goes.
    public func broadcast(_ method: String, _ params: JSONValue?) {
        broadcast(method, params, to: { _ in true })
    }

    /// Tell only the connections `wanted` picks, in the same order and on the same
    /// queues as everything else they are told (034).
    ///
    /// For what belongs to somebody: the folder a phone is watching, the shell it has
    /// open. The rest of what the daemon says still goes to everyone. A phone on WiFi
    /// should not carry an unrelated agent's build output because a Mac window happens
    /// to have that shell open.
    public func broadcast(_ method: String, _ params: JSONValue?,
                          to wanted: @Sendable (ConnectionContext) -> Bool) {
        for (connection, queue, context) in connections.allAddressed where wanted(context) {
            queue.async {
                do {
                    try connection.notify(method, params)
                } catch {
                    // Closed, or stuck past the wait. Either way this connection has
                    // missed something, and a client that carried on would be showing
                    // a list that is no longer true. Half a line may also be on the
                    // wire. Closing is what tells it to start again.
                    Task { await connection.close() }
                }
            }
        }
    }

    /// How long a write to one client may block before that client is given up on.
    /// Long enough for a window busy for a moment; a client that has read nothing for
    /// this long has stopped.
    static let sendWait = timeval(tv_sec: 10, tv_usec: 0)

    /// Bound every blocking write on this descriptor by `sendWait`.
    static func limitSendWait(_ fd: Int32) {
        var wait = sendWait
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
    }

    public var connectionCount: Int { connections.count }

    public func stop() {
        guard stopped.set() else { return }
        if listenFD >= 0 { close(listenFD) }
        unlink(url.path)
        for connection in connections.all {
            Task { await connection.close() }
        }
    }
}

final class ConnectionSet: @unchecked Sendable {
    private let lock = NSLock()
    private var connections: [ObjectIdentifier: JSONRPCConnection] = [:]
    /// The queue each connection's notifications go out on, in order.
    private var queues: [ObjectIdentifier: DispatchQueue] = [:]
    /// Who each connection is, read as it is sent to: a window becomes a device when it
    /// says so, after it was added here.
    private var identities: [ObjectIdentifier: DaemonServer.ConnectionIdentity] = [:]

    func add(_ connection: JSONRPCConnection, queue: DispatchQueue,
             identity: DaemonServer.ConnectionIdentity) {
        lock.lock(); defer { lock.unlock() }
        connections[ObjectIdentifier(connection)] = connection
        queues[ObjectIdentifier(connection)] = queue
        identities[ObjectIdentifier(connection)] = identity
    }

    func remove(_ connection: JSONRPCConnection) {
        lock.lock(); defer { lock.unlock() }
        connections.removeValue(forKey: ObjectIdentifier(connection))
        queues.removeValue(forKey: ObjectIdentifier(connection))
        identities.removeValue(forKey: ObjectIdentifier(connection))
    }

    var allAddressed: [(JSONRPCConnection, DispatchQueue, DaemonServer.ConnectionContext)] {
        lock.lock(); defer { lock.unlock() }
        return connections.compactMap { key, connection in
            guard let queue = queues[key], let identity = identities[key] else { return nil }
            return (connection, queue, identity.context)
        }
    }

    var all: [JSONRPCConnection] {
        lock.lock(); defer { lock.unlock() }
        return Array(connections.values)
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return connections.count
    }
}
