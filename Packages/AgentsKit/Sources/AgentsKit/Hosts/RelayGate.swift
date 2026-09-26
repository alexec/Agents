#if canImport(Darwin)
import Darwin
#elseif canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#endif
import AgentsKitCore
import Foundation

/// The server end of a sign-in relay (047): a TCP port on the server's loopback that a
/// runtime is pointed at, piped to the Unix socket the window's ssh forwards back to the Mac.
///
/// A runtime can only be given a URL, so the relay needs a TCP port; a TCP port on loopback
/// can be reached by every account on the server; and whoever reaches it signs in as the
/// Mac's person. So each connection is let through only when the process that made it runs
/// as the same account as this daemon: `/proc/net/tcp` names the owner of every socket, and
/// the connecting one is the entry whose ends are this connection's, reversed. Anything
/// else is closed before a byte is read. The socket at the other end was made by sshd
/// owner-only (`StreamLocalBindMask` 0177), so that half needs no check of its own.
///
/// Bytes only. TLS is ended on the Mac, which holds the certificate's key: the server holds
/// nothing a stranger could use.
public final class RelayGate: @unchecked Sendable {
    public let port: UInt16
    private let listener: Int32
    private let target: String
    private let ownerCheck: @Sendable (_ clientPort: UInt16, _ gatePort: UInt16) -> Bool
    private let lock = NSLock()
    private var closed = false

    /// Listen on `127.0.0.1` on a free port, piping to the Unix socket at `target`.
    /// `ownerCheck` is `/proc/net/tcp` by default; tests give their own.
    public init(target: String,
                ownerCheck: (@Sendable (UInt16, UInt16) -> Bool)? = nil) throws {
        self.target = target
        self.ownerCheck = ownerCheck ?? { client, gate in RelayGate.sameAccount(clientPort: client, gatePort: gate) }
        let fd = RelayGate.tcpSocket()
        guard fd >= 0 else { throw Failure.socket(errno) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, Darwin_or_Glibc_listen(fd, 16) == 0 else {
            let error = errno
            POSIX.close(fd)
            throw Failure.socket(error)
        }
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        listener = fd
        port = UInt16(bigEndian: actual.sin_port)
        let thread = Thread { [weak self] in self?.acceptLoop() }
        thread.name = "relay-gate"
        thread.start()
    }

    public enum Failure: Error, Equatable { case socket(Int32) }

    public func close() {
        lock.lock()
        let wasClosed = closed
        closed = true
        lock.unlock()
        if !wasClosed {
            shutdown(listener, Int32(SHUT_RDWR))
            POSIX.close(listener)
        }
    }

    deinit { close() }

    private var isClosed: Bool { lock.lock(); defer { lock.unlock() }; return closed }

    private func acceptLoop() {
        while !isClosed {
            var peer = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let client = withUnsafeMutablePointer(to: &peer) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(listener, $0, &length) }
            }
            guard client >= 0 else {
                if isClosed { return }
                continue
            }
            let clientPort = UInt16(bigEndian: peer.sin_port)
            guard ownerCheck(clientPort, port) else {
                DaemonLog.shared.write("relay gate: refused a connection from another account")
                POSIX.close(client)
                continue
            }
            let upstream = POSIX.unixStreamSocket()
            var address = POSIX.unixAddress(target)
            let connected = upstream >= 0 && withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    POSIX.connect(upstream, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            } == 0
            guard connected else {
                DaemonLog.shared.write("relay gate: the Mac's relay is not reachable at \(target)")
                if upstream >= 0 { POSIX.close(upstream) }
                POSIX.close(client)
                continue
            }
            Self.pipe(client, upstream)
        }
    }

    /// Copy both ways until either side closes, then close both.
    private static func pipe(_ a: Int32, _ b: Int32) {
        let done = DispatchGroup()
        for (from, to) in [(a, b), (b, a)] {
            done.enter()
            let thread = Thread {
                var buffer = [UInt8](repeating: 0, count: 65536)
                while true {
                    let n = buffer.withUnsafeMutableBytes { POSIX.read(from, $0.baseAddress, 65536) }
                    if n <= 0 { break }
                    var sent = 0
                    while sent < n {
                        let w = buffer.withUnsafeBytes { POSIX.write(to, $0.baseAddress! + sent, n - sent) }
                        if w <= 0 { break }
                        sent += w
                    }
                    if sent < n { break }
                }
                shutdown(to, Int32(SHUT_WR))
                done.leave()
            }
            thread.start()
        }
        Thread {
            done.wait()
            POSIX.close(a)
            POSIX.close(b)
        }.start()
    }

    private static func tcpSocket() -> Int32 {
        #if canImport(Glibc) && !canImport(Musl)
        socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
        socket(AF_INET, SOCK_STREAM, 0)
        #endif
    }

    // MARK: Who is connecting

    /// Whether the socket connecting from `clientPort` to `gatePort` on loopback belongs to
    /// this process's account, read from `/proc/net/tcp`. False when it cannot be told:
    /// a gate that cannot check lets nobody through.
    public static func sameAccount(clientPort: UInt16, gatePort: UInt16,
                                   table: String? = nil, uid: UInt32 = UInt32(getuid())) -> Bool {
        guard let text = table ?? (try? String(contentsOfFile: "/proc/net/tcp", encoding: .utf8)) else { return false }
        return owner(of: clientPort, connectedTo: gatePort, in: text) == uid
    }

    /// The `uid` column of the entry whose local end is `127.0.0.1:clientPort` and whose
    /// remote end is `127.0.0.1:gatePort`, in `/proc/net/tcp`'s format.
    static func owner(of clientPort: UInt16, connectedTo gatePort: UInt16, in table: String) -> UInt32? {
        let local = String(format: "0100007F:%04X", clientPort)
        let remote = String(format: "0100007F:%04X", gatePort)
        for line in table.split(separator: "\n").dropFirst() {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count > 7, fields[1] == local, fields[2] == remote else { continue }
            return UInt32(fields[7])
        }
        return nil
    }
}

@inline(__always)
private func Darwin_or_Glibc_listen(_ fd: Int32, _ backlog: Int32) -> Int32 {
    #if canImport(Darwin)
    Darwin.listen(fd, backlog)
    #elseif canImport(Musl)
    Musl.listen(fd, backlog)
    #else
    Glibc.listen(fd, backlog)
    #endif
}
