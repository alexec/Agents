#if os(macOS)
import Foundation
import Testing
@testable import AgentsKit

/// An accept loop outlives a failed `accept` (#201).
///
/// The daemon's loop returned on its first failure, so one descriptor spike left
/// daemon.sock taking nobody for the rest of the process's life, with the daemon alive at
/// 0 % CPU. The relay gate's and the tunnel socket's loops spun a core instead.
@Suite("A socket that ran out of descriptors", .timeLimit(.minutes(1)))
struct AcceptRecoveryTests {
    @Test func runningOutIsWaitedOutLongerEachTimeUpToASecond() {
        let waits = Waits()
        let failures = AcceptFailures(name: "test") { waits.list.append($0) }
        for error in [EMFILE, ENFILE, ENOBUFS, ENOMEM, EMFILE, EMFILE, EMFILE, EMFILE, EMFILE] {
            #expect(failures.after(error, listener: -1) == .retry)
        }
        let doubling = (0..<7).map { AcceptFailures.firstWait * pow(2, Double($0)) }
        #expect(waits.list == doubling + [1, 1])

        failures.accepted()
        _ = failures.after(EMFILE, listener: -1)
        #expect(waits.list.last == AcceptFailures.firstWait, "a connection taken starts the waits again")
    }

    @Test func aConnectionThatWentIsSkippedAndOnlyALostListenerEnds() {
        let waits = Waits()
        let failures = AcceptFailures(name: "test") { waits.list.append($0) }
        #expect(failures.after(ECONNABORTED, listener: -1) == .retry)
        #expect(failures.after(EINTR, listener: -1) == .retry)
        #expect(waits.list.isEmpty, "nothing to wait out")
        #expect(failures.after(EBADF, listener: -1) == .stop)
        #expect(failures.after(EINVAL, listener: -1) == .stop)
    }

    /// The issue's test: a daemon socket with few descriptors, run out by connections, all
    /// closed again, and `daemon/ping` still answers. In a process of its own, because out
    /// of descriptors is the whole process's state.
    @Test func theDaemonSocketAnswersAgainOnceItHasDescriptorsAgain() async throws {
        let path = "/tmp/agt-accept-\(UUID().uuidString.prefix(8))"
        defer { unlink(path); unlink(path + ".log") }
        let probe = Process()
        probe.executableURL = Bundle(for: Marker.self).bundleURL
            .deletingLastPathComponent().appendingPathComponent("accept-probe")
        probe.arguments = [path, "40"]
        let input = Pipe()
        let output = Pipe()
        probe.standardInput = input
        probe.standardOutput = output
        try probe.run()
        defer { probe.terminate() }
        let reading = output.fileHandleForReading
        let ready = await offThePool { reading.availableData }
        try #require(String(decoding: ready, as: UTF8.self).contains("ready"))

        // Three times what it has: most wait in the queue with nobody taking them.
        var held: [Int32] = []
        defer { held.forEach { close($0) } }
        for _ in 0..<120 {
            let fd = Self.connect(path)
            if fd >= 0 { held.append(fd) }
        }
        let open = held
        // Out of descriptors, the oldest waiting are taken on the spare and closed, so they
        // hear "closed" rather than waiting for good. That they do is also the proof that
        // it ran out.
        await eventually("a waiting connection was turned away") {
            open.contains { Self.closedByPeer($0) }
        }

        held.forEach { close($0) }
        held = []
        await eventually("daemon/ping answered after running out") {
            await offThePool { Self.ping(path) }
        }
        #expect(probe.isRunning)
        let log = (try? String(contentsOfFile: path + ".log", encoding: .utf8)) ?? ""
        #expect(log.components(separatedBy: "accept failed").count == 2, "said once, then counted: \(log)")
        #expect(log.contains("socket: accepting again"))
    }

    // MARK: Helpers

    private final class Marker {}
    private final class Waits: @unchecked Sendable { var list: [TimeInterval] = [] }

    private static func connect(_ path: String) -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            path.withCString { strncpy(UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: CChar.self), $0, 103) }
        }
        let joined = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard joined == 0 else { close(fd); return -1 }
        return fd
    }

    /// Whether the other end has closed, without waiting; anything it said is read past.
    private static func closedByPeer(_ fd: Int32) -> Bool {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = recv(fd, &buffer, buffer.count, MSG_DONTWAIT)
            if n == 0 { return true }
            if n < 0 { return errno != EAGAIN && errno != EWOULDBLOCK }
        }
    }

    /// One `daemon/ping` on a fresh connection, answered within three seconds.
    private static func ping(_ path: String) -> Bool {
        let fd = connect(path)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let line = Array(#"{"jsonrpc":"2.0","id":1,"method":"daemon/ping"}"#.utf8) + [0x0A]
        guard write(fd, line, line.count) == line.count else { return false }
        var reply = [UInt8]()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while !reply.contains(0x0A) {
            let n = read(fd, &buffer, buffer.count)
            if n <= 0 { return false }
            reply += buffer[0..<n]
        }
        return String(decoding: reply, as: UTF8.self).contains(#""result""#)
    }
}
#endif
