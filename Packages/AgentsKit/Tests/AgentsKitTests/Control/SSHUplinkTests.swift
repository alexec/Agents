import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// A server reached over ssh, as the router sees it (058, T040): channels become socket
/// connections to the forward, which here is the daemon's own socket.
@Suite("A host reached over ssh", .serialized, .timeLimit(.minutes(1)))
struct SSHUplinkTests {
    final class Heard: @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [(String, ConnectionRole, Surface?)] = []
        func add(_ method: String, _ context: DaemonServer.ConnectionContext) {
            lock.withLock { calls.append((method, context.role, context.surface)) }
        }
        var all: [(String, ConnectionRole, Surface?)] { lock.withLock { calls } }
    }

    final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var heard: [String] = []
        func add(_ line: String) { lock.withLock { heard.append(line) } }
        var all: [String] { lock.withLock { heard } }
    }

    func server(_ heard: Heard) throws -> (DaemonServer, URL) {
        let socket = URL(fileURLWithPath: "/tmp/ssh-up-\(UUID().uuidString.prefix(6)).sock")
        let server = DaemonServer(url: socket) { context, method, _ in
            heard.add(method, context)
            return .success(["ok": true])
        }
        try server.start()
        return (server, socket)
    }

    func ask(_ id: Int, _ method: String) throws -> String {
        try JSONRPCCodec.encode(.request(id: .number(id), method: method, params: nil))
    }

    @Test func eachChannelIsAConnectionOfItsOwnAndADevicesIsBoundToIt() async throws {
        let heard = Heard()
        let (server, socket) = try server(heard)
        defer { server.stop() }
        let uplink = SSHUplink(socket: socket)
        defer { uplink.close() }
        let lines = Lines()
        let reading = Task { for try await line in uplink.lines() { lines.add(line) } }
        defer { reading.cancel() }

        let phone = UUID()
        try uplink.write(line: ControlWire.open(1, .init(grant: .operator, client: "window")))
        try uplink.write(line: ControlWire.open(2, .init(grant: .device, client: phone.uuidString, device: phone)))
        await eventually { server.connectionCount == 2 }
        try uplink.write(line: ControlWire.channel(1, message: ask(1, DaemonAPI.Method.agentsList)))
        try uplink.write(line: ControlWire.channel(2, message: ask(1, DaemonAPI.Method.agentsList)))
        try uplink.write(line: ControlWire.channel(2, message: ask(2, DaemonAPI.Method.credentialsLend)))
        await eventually { lines.all.count == 3 }

        let lists = heard.all.filter { $0.0 == DaemonAPI.Method.agentsList }
        #expect(lists.contains { $0.1 == .control })
        #expect(lists.contains { $0.1 == .device && $0.2 == .device(phone) })
        // The daemon refuses the device what it may not do, as it always has.
        #expect(lines.all.contains { $0.hasPrefix(#"{"c":2"#) && $0.contains("\(DaemonAPI.Failure.notPermitted)") })
        // The binding's own answer was not passed on.
        #expect(!lines.all.contains { $0.contains("control-bind-device") })
    }

    @Test func closingAChannelEndsItsConnectionAndAConnectionThatEndsClosesItsChannel() async throws {
        let heard = Heard()
        let (server, socket) = try server(heard)
        let uplink = SSHUplink(socket: socket)
        defer { uplink.close() }
        let lines = Lines()
        let reading = Task { for try await line in uplink.lines() { lines.add(line) } }
        defer { reading.cancel() }

        try uplink.write(line: ControlWire.open(1, .init(grant: .operator, client: "a")))
        try uplink.write(line: ControlWire.open(2, .init(grant: .operator, client: "b")))
        await eventually { server.connectionCount == 2 }
        try uplink.write(line: ControlWire.close(1))
        await eventually { server.connectionCount == 1 }
        // The server going takes the other channel with it, and the router is told.
        server.stop()
        await eventually { lines.all.contains(ControlWire.close(2)) }
    }
}
