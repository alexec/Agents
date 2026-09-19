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
    public typealias Handler = @Sendable (String, JSONValue?) async -> Result<JSONValue, JSONRPCError>

    private let url: URL
    private let handler: Handler
    private var listenFD: Int32 = -1
    private let connections = ConnectionSet()
    private let stopped = ManagedAtomicFlag()
    private let onConnectionCountChanged: @Sendable (Int) -> Void

    public init(url: URL,
                onConnectionCountChanged: @escaping @Sendable (Int) -> Void = { _ in },
                handler: @escaping Handler) {
        self.url = url
        self.handler = handler
        self.onConnectionCountChanged = onConnectionCountChanged
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
        // nobody and waits for a reply that is never coming.
        fcntl(listenFD, F_SETFD, FD_CLOEXEC)

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
                guard let self, !self.stopped.isSet else { close(fd); return }
                // accept() hands back a descriptor with the flag clear however the
                // listener was opened, so each window's connection says it again.
                fcntl(fd, F_SETFD, FD_CLOEXEC)
                self.accepted(fd)
            }
        }
        thread.name = "AgentsKit.DaemonServer"
        thread.start()
    }

    private func accepted(_ fd: Int32) {
        let transport = FDTransport(socket: fd)
        let connection = JSONRPCConnection(transport: transport, handler: handler)
        connections.add(connection)
        onConnectionCountChanged(connections.count)
        Task {
            await connection.start()
            // The connection ends when the window goes. Which it will: quitting the
            // app is the ordinary case, not the exceptional one.
            for await _ in connection.incomingNotifications() {}
            self.connections.remove(connection)
            self.onConnectionCountChanged(self.connections.count)
        }
    }

    /// Tell every window at once.
    public func broadcast(_ method: String, _ params: JSONValue?) {
        for connection in connections.all {
            Task { try? await connection.notify(method, params) }
        }
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

    func add(_ connection: JSONRPCConnection) {
        lock.lock(); defer { lock.unlock() }
        connections[ObjectIdentifier(connection)] = connection
    }

    func remove(_ connection: JSONRPCConnection) {
        lock.lock(); defer { lock.unlock() }
        connections.removeValue(forKey: ObjectIdentifier(connection))
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
