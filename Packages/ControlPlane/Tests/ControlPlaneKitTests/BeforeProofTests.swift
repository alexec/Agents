import AgentsKit
import AgentsKitCore
import ControlDial
@testable import ControlPlaneKit
import Foundation
import Testing
#if canImport(Glibc)
import Glibc
#endif

/// What a connection may cost the control plane before it has proved anything, and what
/// one unreadable record may cost everyone else (#206).
@Suite("Before a member proves itself", .timeLimit(.minutes(2)))
struct BeforeProofTests {
    let base = ControlServiceTests()

    // MARK: Unreadable records

    /// `chmod 000` on one client's file: the control plane still starts, the others still
    /// connect, and that one is told to try again, never that it is unknown.
    @Test func aClientFileThatCannotBeReadLetsTheControlPlaneStartAndTheOthersConnect() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("store-\(UUID().uuidString)")
        let first = try await base.start(store: FolderStore(root: root))
        let (locked, _, lockedCredentials) = try await base.pairedClient(
            at: first.url, code: try await first.service.codes.issue(.client).text)
        let (_, _, otherCredentials) = try await base.pairedClient(
            at: first.url, code: try await first.service.codes.issue(.client).text)
        await first.service.stop()

        let path = root.appendingPathComponent(ControlRecords.clientKey(locked)).path
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: path)

        let again = try await base.start(store: FolderStore(root: root))
        defer { Task { await again.service.stop() } }
        let joined = try await base.join(again.url, otherCredentials)
        joined.close()
        await #expect(throws: ControlAuth.Refusal(.unavailable)) {
            _ = try await base.join(again.url, lockedCredentials)
        }
        // The 15 s re-read keeps it ready.
        await again.service.refresh()
        let probe = try await URLSession.shared.data(from: again.url.appendingPathComponent("readyz"))
        #expect((probe.1 as? HTTPURLResponse)?.statusCode == 200)
    }

    // MARK: Before the upgrade

    /// 300 connections that never send a byte: a real client still joins while they are
    /// open, and no more than the gate's worth are held.
    @Test func threeHundredIdleConnectionsStillLetARealClientJoin() async throws {
        let running = try await base.start()
        defer { Task { await running.service.stop() } }
        let (_, _, credentials) = try await base.pairedClient(
            at: running.url, code: try await running.service.codes.issue(.client).text)

        var idle: [Int32] = []
        defer { for fd in idle { close(fd) } }
        // Paced a little, so the kernel's backlog of 256 is not what refuses them; under
        // the whole suite's load a few may be reset before they are accepted all the same.
        for index in 0..<300 {
            if let fd = try? Raw.connect(port: running.port) { idle.append(fd) }
            if index % 25 == 24 { try await Task.sleep(for: .milliseconds(20)) }
        }
        #expect(idle.count > 2 * UnprovenGate.defaultMost)
        await eventually { running.service.unproven.count == UnprovenGate.defaultMost }
        #expect(running.service.unproven.count <= UnprovenGate.defaultMost)

        // Past the gate, the oldest are closed to make room.
        let closed = idle.filter { Raw.closedByPeer($0, within: 0.05) }.count
        #expect(closed >= idle.count - UnprovenGate.defaultMost)

        // A real client gets in now, not once the strangers time out: it takes the oldest
        // one's place and proves itself before it is the oldest.
        let started = Date()
        let joined = try await base.join(running.url, credentials)
        joined.close()
        #expect(Date().timeIntervalSince(started) < 2)
    }

    /// One connection that never sends a byte is closed within the idle time, and gives
    /// back its place.
    @Test func aSilentConnectionIsClosedWithinTheIdleTime() async throws {
        let running = try await base.start()
        defer { Task { await running.service.stop() } }
        let fd = try Raw.connect(port: running.port)
        defer { close(fd) }
        await eventually { running.service.unproven.count == 1 }
        #expect(!Raw.closedByPeer(fd, within: 8))
        #expect(Raw.closedByPeer(fd, within: 4))
        await eventually { running.service.unproven.count == 0 }
    }

    /// A connection that upgrades and then sends more than a stranger may before `ok` is
    /// closed: a 64 MB frame is never gathered for it.
    @Test func aLargeFrameBeforeOkIsRefusedBeforeItIsGathered() async throws {
        let running = try await base.start()
        defer { Task { await running.service.stop() } }
        let fd = try Raw.connect(port: running.port)
        defer { close(fd) }
        try Raw.send(fd, Data(("GET /v1/connect HTTP/1.1\r\nHost: 127.0.0.1:\(running.port)\r\nUpgrade: websocket\r\n"
            + "Connection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n").utf8))
        let head = Raw.read(fd, within: 5)
        #expect(String(decoding: head, as: UTF8.self).hasPrefix("HTTP/1.1 101"))
        // A masked text frame that says it carries 16 MB, then the first 200 KB of it.
        var frame = Data([0x81, 0xFF])
        withUnsafeBytes(of: UInt64(16 << 20).bigEndian) { frame.append(contentsOf: $0) }
        frame.append(contentsOf: [1, 2, 3, 4])
        _ = try? Raw.send(fd, frame + Data(count: 200 << 10))
        #expect(Raw.closedByPeer(fd, within: 5))
        await eventually { running.service.unproven.count == 0 }
    }
}

/// Plain sockets, for peers that misbehave below the WebSocket.
enum Raw {
    struct Failed: Error { var errno: Int32 }

    static func connect(port: Int) throws -> Int32 {
        #if canImport(Glibc)
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #endif
        guard fd >= 0 else { throw Failed(errno: errno) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Foundation.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            let failed = errno
            close(fd)
            throw Failed(errno: failed)
        }
        return fd
    }

    static func send(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let wrote = write(fd, bytes.baseAddress! + offset, bytes.count - offset)
                guard wrote > 0 else { throw Failed(errno: errno) }
                offset += wrote
            }
        }
    }

    private static func wait(_ fd: Int32, within seconds: Double) -> Bool {
        var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        return poll(&poller, 1, Int32(seconds * 1000)) > 0
    }

    /// What arrives first, within `seconds`.
    static func read(_ fd: Int32, within seconds: Double) -> Data {
        guard wait(fd, within: seconds) else { return Data() }
        var buffer = [UInt8](repeating: 0, count: 4096)
        let got = Foundation.read(fd, &buffer, buffer.count)
        return got > 0 ? Data(buffer[0..<got]) : Data()
    }

    /// The other end closed it (end of file or a reset) within `seconds`; anything it sent
    /// first is read and dropped.
    static func closedByPeer(_ fd: Int32, within seconds: Double) -> Bool {
        let until = Date().addingTimeInterval(seconds)
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let left = until.timeIntervalSinceNow
            guard left > 0, wait(fd, within: left) else { return false }
            let got = Foundation.read(fd, &buffer, buffer.count)
            if got <= 0 { return true }
        }
    }
}
