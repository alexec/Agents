import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// One client that stops reading must not cost every other client its news.
///
/// Every notification used to go out on one queue for all connections, with blocking
/// writes and no limit on them. A window that stopped reading filled its socket, the
/// write to it never returned, and every other window and the bridge heard nothing
/// from then on.
@Suite("A client that stops reading", .timeLimit(.minutes(1)))
struct BroadcastIsolationTests {
    private func connect(_ path: String) -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            path.withCString { strncpy(UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: CChar.self), $0, 103) }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, size) }
        }
        precondition(result == 0, "could not connect: \(errno)")
        return fd
    }

    /// Everything `fd` receives until `marker` appears or `deadline` passes.
    private func read(_ fd: Int32, until marker: String, deadline: Date) -> Bool {
        var wait = timeval(tv_sec: 0, tv_usec: 200_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
        var received = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        let needle = Data(marker.utf8)
        while Date() < deadline {
            let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                received.append(contentsOf: buffer[0..<n])
                if received.range(of: needle) != nil { return true }
                // Only the tail can still hold the start of the marker.
                if received.count > 1_000_000 { received = received.suffix(needle.count) }
            } else if n == 0 {
                return false
            }
        }
        return false
    }

    @Test func aStalledClientDoesNotSilenceTheOthers() async throws {
        let path = "/tmp/ag-bcast-\(UUID().uuidString.prefix(8)).sock"
        let server = DaemonServer(url: URL(fileURLWithPath: path)) { _, _, _ in .success(.null) }
        try server.start()
        defer { server.stop() }

        let stalled = connect(path)   // connects, and never reads a byte
        let listening = connect(path)
        defer { close(stalled); close(listening) }
        await eventually("both are connected") { server.connectionCount == 2 }

        // Several times what a local socket buffers, so the stalled client's write
        // blocks and stays blocked.
        let big = JSONValue.string(String(repeating: "x", count: 32 * 1024))
        for _ in 0..<8 { server.broadcast("test/big", big) }
        server.broadcast("test/marker", nil)

        // Read on a thread of its own. A blocking read on the cooperative pool starves
        // every other test running beside this one.
        let heard = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            Thread { [self] in
                done.resume(returning: read(listening, until: "test/marker",
                                            deadline: Date().addingTimeInterval(5)))
            }.start()
        }
        #expect(heard, "the listening client heard everything, stalled neighbour or not")
    }
}
