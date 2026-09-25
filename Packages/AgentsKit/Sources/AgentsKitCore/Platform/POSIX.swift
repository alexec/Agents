#if canImport(Darwin)
import Darwin
#elseif canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#endif

/// The C library, named once (037).
///
/// The daemon calls `read`, `write`, `close`, `connect` and `kill` by module name so a
/// method of the same name nearby can never be picked instead. That module is `Darwin`
/// on the Mac and `Musl` in the static Linux build of `agentsd`, so the name lives here
/// and nowhere else.
public enum POSIX {
    @inline(__always)
    public static func read(_ fd: Int32, _ buffer: UnsafeMutableRawPointer?, _ count: Int) -> Int {
        #if canImport(Darwin)
        Darwin.read(fd, buffer, count)
        #elseif canImport(Musl)
        Musl.read(fd, buffer, count)
        #else
        Glibc.read(fd, buffer, count)
        #endif
    }

    @inline(__always)
    public static func write(_ fd: Int32, _ buffer: UnsafeRawPointer?, _ count: Int) -> Int {
        #if canImport(Darwin)
        Darwin.write(fd, buffer, count)
        #elseif canImport(Musl)
        Musl.write(fd, buffer, count)
        #else
        Glibc.write(fd, buffer, count)
        #endif
    }

    @inline(__always) @discardableResult
    public static func close(_ fd: Int32) -> Int32 {
        #if canImport(Darwin)
        Darwin.close(fd)
        #elseif canImport(Musl)
        Musl.close(fd)
        #else
        Glibc.close(fd)
        #endif
    }

    @inline(__always)
    public static func connect(_ fd: Int32, _ address: UnsafePointer<sockaddr>, _ length: socklen_t) -> Int32 {
        #if canImport(Darwin)
        Darwin.connect(fd, address, length)
        #elseif canImport(Musl)
        Musl.connect(fd, address, length)
        #else
        Glibc.connect(fd, address, length)
        #endif
    }

    @inline(__always) @discardableResult
    public static func kill(_ pid: pid_t, _ signal: Int32) -> Int32 {
        #if canImport(Darwin)
        Darwin.kill(pid, signal)
        #elseif canImport(Musl)
        Musl.kill(pid, signal)
        #else
        Glibc.kill(pid, signal)
        #endif
    }

    /// `socket(AF_UNIX, SOCK_STREAM, 0)`. glibc spells the type as an enum wrapper; Darwin and musl do not.
    public static func unixStreamSocket() -> Int32 {
        #if canImport(Glibc) && !canImport(Musl)
        socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        #else
        socket(AF_UNIX, SOCK_STREAM, 0)
        #endif
    }

    /// What `sockaddr_un.sun_path` holds, terminator included: 104 on the Mac, 108 on
    /// Linux. Paths are held to the Mac's limit everywhere, so a root that works on one
    /// works on the other.
    public static let socketPathLimit = 104

    /// A `sockaddr_un` for `path`, which must already be under `socketPathLimit`.
    public static func unixAddress(_ path: String) -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            path.withCString { source in
                strncpy(UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: CChar.self), source,
                        socketPathLimit - 1)
            }
        }
        return address
    }
}
