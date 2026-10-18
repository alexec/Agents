import Foundation

/// A connected Unix socket, close-on-exec, or `couldNotConnect`. The Mac's daemon socket,
/// a server's forwarded one and the window's local socket (#1118) are reached the same way
/// (037).
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
