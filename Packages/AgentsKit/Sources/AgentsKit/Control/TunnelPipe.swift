#if canImport(Darwin)
import Darwin
#elseif canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#endif
import AgentsKitCore
import Foundation

/// Bytes over a channel of the control plane's wire (058, T091): a sign-in relay's TLS,
/// from the borrowing host's gate to the lending Mac's relay, through the control plane.
///
/// A channel carries lines, so each chunk goes as a JSON string of its base64. Nothing on
/// the way reads it: TLS is ended on the Mac, so the control plane and its store see only
/// ciphertext. Either end closing closes the other.
public enum TunnelPipe {
    /// One chunk as a line on the wire.
    public static func line(_ bytes: Data) -> String {
        "\"" + bytes.base64EncodedString() + "\""
    }

    /// One line off the wire, as bytes; nil for anything that is not a chunk.
    public static func bytes(_ line: String) -> Data? {
        guard line.count >= 2, line.first == "\"", line.last == "\"" else { return nil }
        return Data(base64Encoded: String(line.dropFirst().dropLast()))
    }

    /// Copy between a socket and a channel until either ends, then close both.
    public static func pump(_ fd: Int32, _ channel: any LineTransport) {
        let reading = Thread {
            var buffer = [UInt8](repeating: 0, count: 32768)
            while true {
                let n = buffer.withUnsafeMutableBytes { POSIX.read(fd, $0.baseAddress, 32768) }
                if n <= 0 { break }
                do { try channel.write(line: line(Data(buffer[0..<n]))) } catch { break }
            }
            channel.close()
        }
        reading.name = "tunnel-out"
        reading.start()
        Task.detached {
            do {
                for try await line in channel.lines() {
                    guard let data = bytes(line) else { continue }
                    let written = data.withUnsafeBytes { raw -> Bool in
                        var sent = 0
                        while sent < raw.count {
                            let w = POSIX.write(fd, raw.baseAddress! + sent, raw.count - sent)
                            if w <= 0 { return false }
                            sent += w
                        }
                        return true
                    }
                    if !written { break }
                }
            } catch {}
            shutdown(fd, Int32(SHUT_RDWR))
            _ = POSIX.close(fd)
            channel.close()
        }
    }

    public struct Failure: Error, CustomStringConvertible, Sendable {
        public var description: String
        public init(_ description: String) { self.description = description }
    }
}

/// The borrowing host's end (058, T091): a Unix socket in its root, where the sign-in
/// relay's gate points, each connection to which becomes a tunnel to the lending Mac.
/// Owner-only, in a folder only this account reads, as sshd's forward was.
public final class TunnelSocket: @unchecked Sendable {
    public let path: String
    private let listener: Int32
    private let open: @Sendable () async throws -> any LineTransport
    private let lock = NSLock()
    private var closed = false

    public init(path: String, open: @escaping @Sendable () async throws -> any LineTransport) throws {
        self.path = path
        self.open = open
        unlink(path)
        let fd = POSIX.unixStreamSocket()
        guard fd >= 0 else { throw TunnelPipe.Failure("no socket: \(errno)") }
        var address = POSIX.unixAddress(path)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, chmod(path, 0o600) == 0, listen(fd, SOMAXCONN) == 0 else {
            _ = POSIX.close(fd)
            throw TunnelPipe.Failure("could not listen at \(path): \(errno)")
        }
        listener = fd
        let thread = Thread { [weak self] in self?.acceptLoop() }
        thread.name = "tunnel-socket"
        thread.start()
    }

    private var isClosed: Bool { lock.withLock { closed } }

    public func close() {
        let was = lock.withLock { () -> Bool in defer { closed = true }; return closed }
        guard !was else { return }
        shutdown(listener, Int32(SHUT_RDWR))
        _ = POSIX.close(listener)
        unlink(path)
    }

    private func acceptLoop() {
        let failures = AcceptFailures(name: "tunnel socket")
        while !isClosed {
            let client = accept(listener, nil, nil)
            guard client >= 0 else {
                // Waited out rather than spun on (#201).
                let error = errno
                if isClosed || failures.after(error, listener: listener) == .stop { return }
                continue
            }
            failures.accepted()
            let open = self.open
            Task.detached {
                do {
                    TunnelPipe.pump(client, try await open())
                } catch {
                    DaemonLog.shared.write("relay: no tunnel to the Mac that lends this sign-in: \(error)")
                    _ = POSIX.close(client)
                }
            }
        }
    }
}
