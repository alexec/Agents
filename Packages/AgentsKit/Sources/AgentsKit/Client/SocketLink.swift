import Foundation

/// A way to reach `agentsd` on this machine: its Unix socket. Nothing is started from
/// here (058): a Mac's daemon is Agents Host's launch agent and a server's is its own, so
/// a client that finds nobody listening says so. `agentsd mcp` reaches its daemon this
/// way for an agent's own tools (FR-021).
public struct SocketLink: DaemonLink {
    private let locations: StoreLocations

    public init(locations: StoreLocations = .default) {
        self.locations = locations
    }

    public func transport() async throws -> any LineTransport {
        FDTransport(socket: try connectUnixSocket(path: locations.socket.path))
    }

    public func start() async throws {
        throw DaemonClient.ConnectError.couldNotConnect
    }
}

public extension DaemonClient {
    /// This machine's daemon, at the socket in its root.
    init(locations: StoreLocations = .default) {
        self.init(link: SocketLink(locations: locations))
    }
}

/// A connected Unix socket, close-on-exec, or `couldNotConnect`. The Mac's daemon socket
/// and a server's forwarded one are reached the same way (037).
public func connectUnixSocket(path: String) throws -> Int32 {
    // The same 104 bytes `DaemonServer` refuses to exceed. Said here too, because
    // a truncated path connects to nothing and reads as "no daemon is running".
    guard path.utf8.count < 104 else { throw DaemonClient.ConnectError.socketPathTooLong(path) }
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw DaemonClient.ConnectError.couldNotConnect }
    // The daemon notices a client has gone when this end closes. A child holding a
    // copy of it would be a client that never leaves.
    _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    _ = withUnsafeMutablePointer(to: &address.sun_path) { pointer in
        path.withCString { source in
            strncpy(UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: CChar.self), source, 103)
        }
    }
    let size = socklen_t(MemoryLayout<sockaddr_un>.size)
    let result = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { POSIX.connect(fd, $0, size) }
    }
    guard result == 0 else {
        close(fd)
        throw DaemonClient.ConnectError.couldNotConnect
    }
    return fd
}
