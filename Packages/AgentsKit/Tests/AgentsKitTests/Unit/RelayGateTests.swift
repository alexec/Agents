import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// The server end of a sign-in relay (047): only this account's processes get through.
@Suite("A relay gate on a server", .timeLimit(.minutes(1)))
struct RelayGateTests {
    /// `/proc/net/tcp` as Linux prints it: a listener on :4B21, a client from :D4F0 owned
    /// by uid 1000, and another client from :D4F2 owned by uid 1001.
    static let table = """
          sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
           0: 0100007F:4B21 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 11111 1 0000000000000000 100 0 0 10 0
           1: 0100007F:D4F0 0100007F:4B21 01 00000000:00000000 00:00000000 00000000  1000        0 22222 1 0000000000000000 20 4 30 10 -1
           2: 0100007F:D4F2 0100007F:4B21 01 00000000:00000000 00:00000000 00000000  1001        0 33333 1 0000000000000000 20 4 30 10 -1
        """

    @Test func theOwnerIsTheEntryWhoseEndsAreThisConnectionsReversed() {
        #expect(RelayGate.owner(of: 0xD4F0, connectedTo: 0x4B21, in: Self.table) == 1000)
        #expect(RelayGate.owner(of: 0xD4F2, connectedTo: 0x4B21, in: Self.table) == 1001)
        #expect(RelayGate.owner(of: 0x1234, connectedTo: 0x4B21, in: Self.table) == nil)
    }

    @Test func aClientOnAnIPv6SocketIsFoundByItsMappedAddress() {
        let table6 = """
              sl  local_address                         remote_address                        st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
               0: 0000000000000000FFFF00000100007F:D4F4 0000000000000000FFFF00000100007F:4B21 01 00000000:00000000 00:00000000 00000000  1000        0 44444 1
            """
        #expect(RelayGate.owner(of: 0xD4F4, connectedTo: 0x4B21, in: table6) == 1000)
        #expect(RelayGate.owner(of: 0xD4F4, connectedTo: 0x4B21, in: Self.table) == nil)
    }

    @Test func aLongFileIsReadToItsEndALineAtATime() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("tcp-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        let lines = (0..<2000).map { "line \($0) " + String(repeating: "x", count: 40) }
        try Data((lines.joined(separator: "\n") + "\nend").utf8).write(to: file)
        var seen: [String] = []
        RelayGate.eachLine(of: file.path) { seen.append(String($0)); return true }
        #expect(seen == lines + ["end"])
    }

    /// The gate stops at the entry it wants rather than reading the rest of the table (#201).
    @Test func readingStopsWhenTheLineIsFound() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("tcp-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data((0..<5000).map { "line \($0)" }.joined(separator: "\n").utf8).write(to: file)
        var seen = 0
        RelayGate.eachLine(of: file.path) { _ in seen += 1; return seen < 3 }
        #expect(seen == 3)
    }

    @Test func onlyTheSameAccountIsLetThrough() {
        #expect(RelayGate.sameAccount(clientPort: 0xD4F0, gatePort: 0x4B21, table: Self.table, uid: 1000))
        #expect(!RelayGate.sameAccount(clientPort: 0xD4F2, gatePort: 0x4B21, table: Self.table, uid: 1000))
        #expect(!RelayGate.sameAccount(clientPort: 0x9999, gatePort: 0x4B21, table: Self.table, uid: 1000),
                "a connection that cannot be found is refused")
        #expect(!RelayGate.sameAccount(clientPort: 0xD4F0, gatePort: 0x4B21, table: "", uid: 1000))
    }

    /// End to end on this Mac, with the check given: bytes go both ways when it passes,
    /// and the connection is closed unread when it does not.
    @Test func bytesGoBothWaysWhenTheCheckPassesAndNotAtAllWhenItFails() throws {
        let folder = URL(fileURLWithPath: "/tmp").appendingPathComponent("gate-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let socketPath = folder.appendingPathComponent("relay.sock").path
        let echo = try EchoServer(path: socketPath)
        defer { echo.stop() }

        let open = try RelayGate(target: socketPath, ownerCheck: { _, _ in true })
        defer { open.close() }
        #expect(try Self.roundTrip(port: open.port, "hello") == "hello")

        let shut = try RelayGate(target: socketPath, ownerCheck: { _, _ in false })
        defer { shut.close() }
        #expect(try Self.roundTrip(port: shut.port, "hello") == "")

        // Both connections are let go once they end, through and refused alike (#201).
        let deadline = Date().addingTimeInterval(5)
        while open.liveConnections + shut.liveConnections > 0, Date() < deadline { usleep(20_000) }
        #expect(open.liveConnections == 0)
        #expect(shut.liveConnections == 0)
    }

    static func roundTrip(port: UInt16, _ text: String) throws -> String {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard connected == 0 else { return "" }
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        _ = text.withCString { write(fd, $0, strlen($0)) }
        shutdown(fd, SHUT_WR)
        var out = [UInt8](repeating: 0, count: 256)
        let n = read(fd, &out, 256)
        return n > 0 ? String(decoding: out[0..<n], as: UTF8.self) : ""
    }

    /// A Unix-socket server that writes back whatever it reads, like the Mac's relay would.
    final class EchoServer: @unchecked Sendable {
        let fd: Int32
        let path: String
        init(path: String) throws {
            self.path = path
            fd = POSIX.unixStreamSocket()
            var address = POSIX.unixAddress(path)
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            guard bound == 0, listen(fd, 4) == 0 else { throw CocoaError(.fileWriteUnknown) }
            let listener = fd
            Thread {
                while true {
                    let client = accept(listener, nil, nil)
                    if client < 0 { return }
                    var buffer = [UInt8](repeating: 0, count: 256)
                    let n = read(client, &buffer, 256)
                    if n > 0 { _ = write(client, buffer, n) }
                    close(client)
                }
            }.start()
        }
        func stop() { shutdown(fd, SHUT_RDWR); close(fd); unlink(path) }
    }
}
