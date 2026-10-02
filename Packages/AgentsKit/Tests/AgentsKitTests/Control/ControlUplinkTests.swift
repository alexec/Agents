import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// The host's side (T016): each channel is a connection with a window's rights (one grant,
/// #111), and a phone's or a browser's is that device's own.
@Suite("A host's uplink to the control plane", .timeLimit(.minutes(1)))
struct ControlUplinkTests {
    final class Heard: @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [(method: String, role: ConnectionRole, surface: Surface?)] = []
        func add(_ method: String, _ context: DaemonServer.ConnectionContext) {
            lock.withLock { calls.append((method, context.role, context.surface)) }
        }
        var all: [(method: String, role: ConnectionRole, surface: Surface?)] { lock.withLock { calls } }
    }

    /// The control plane's end of each uplink the host dials, in order.
    final class Dials: @unchecked Sendable {
        private let lock = NSLock()
        private var ends: [FakeControlEnd] = []
        func add(_ end: FakeControlEnd) { lock.withLock { ends.append(end) } }
        var all: [FakeControlEnd] { lock.withLock { ends } }
    }

    final class FakeControlEnd: @unchecked Sendable {
        let transport: PairedTransport
        private let lock = NSLock()
        private var heard: [String] = []

        init(_ transport: PairedTransport) {
            self.transport = transport
            Task { [weak self] in
                do { for try await line in transport.lines() { self?.lock.withLock { self?.heard.append(line) } } } catch {}
            }
        }

        var lines: [String] { lock.withLock { heard } }

        func lines(on channel: Int) -> [String] {
            lines.compactMap {
                if case .message(channel, let message)? = try? ControlWire.readHost($0) { return message }
                return nil
            }
        }

        func open(_ channel: Int, device: UUID? = nil) throws {
            try transport.write(line: ControlWire.open(channel, .init(client: UUID().uuidString, device: device)))
        }

        func ask(_ channel: Int, id: Int, _ method: String) throws {
            let message = try JSONRPCCodec.encode(.request(id: .number(id), method: method, params: nil))
            try transport.write(line: ControlWire.channel(channel, message: message))
        }
    }

    func host(heard: Heard, dials: Dials) -> (DaemonServer, ControlUplink) {
        let server = DaemonServer(url: URL(fileURLWithPath: "/tmp/unused-\(UUID()).sock")) { context, method, _ in
            heard.add(method, context)
            return .success(["ok": true])
        }
        let uplink = ControlUplink(server: server,
                                   hello: DaemonAPI.HostHello(host: .mac, version: "1", platform: "test", machineID: "m")) {
            let (ours, theirs) = PairedTransport.pair()
            dials.add(FakeControlEnd(theirs))
            return ours
        }
        uplink.start()
        return (server, uplink)
    }

    /// A control plane that cannot be reached, then a network change (#82): the uplink dials
    /// at once, not when its half-minute wait is up.
    @Test func aNetworkChangeDialsAtOnceRatherThanAfterTheWait() async throws {
        final class Count: @unchecked Sendable {
            let lock = NSLock()
            var dials = 0
            var naps: [Duration] = []
        }
        let count = Count()
        let server = DaemonServer(url: URL(fileURLWithPath: "/tmp/unused-\(UUID()).sock")) { _, _, _ in .success(["ok": true]) }
        // A wait that never ends by itself: only a nudge ends it.
        let backoff = Backoff(first: .seconds(30), longest: .seconds(30)) { duration in
            count.lock.withLock { count.naps.append(duration) }
            try await Task.sleep(for: .seconds(3600))
        }
        let uplink = ControlUplink(server: server,
                                   hello: DaemonAPI.HostHello(host: .mac, version: "1", platform: "test", machineID: "m"),
                                   backoff: backoff) {
            count.lock.withLock { count.dials += 1 }
            throw URLError(.cannotConnectToHost)
        }
        uplink.start()
        defer { uplink.stop() }
        await eventually { count.lock.withLock { count.dials == 1 && count.naps.count == 1 } }
        #expect(uplink.goBackNow() == .cutShort)
        await eventually { count.lock.withLock { count.dials == 2 } }
        // And back to waiting, from the first wait again.
        await eventually { count.lock.withLock { count.naps.count == 2 } }
    }

    @Test func itSaysHelloOnChannelZeroWhenItConnects() async throws {
        let dials = Dials()
        let (_, uplink) = host(heard: Heard(), dials: dials)
        defer { uplink.stop() }
        await eventually { dials.all.first?.lines(on: 0).first?.contains(DaemonAPI.Method.hostHello) == true }
    }

    @Test func aWindowsChannelAndAPhonesMayBothLend() async throws {
        let heard = Heard()
        let dials = Dials()
        let (_, uplink) = host(heard: heard, dials: dials)
        defer { uplink.stop() }
        await eventually { !dials.all.isEmpty }
        try #require(!dials.all.isEmpty)
        let control = dials.all[0]
        let phone = UUID()
        try control.open(1)
        try control.open(2, device: phone)
        await eventually { uplink.openChannels == [1, 2] }

        try control.ask(1, id: 1, DaemonAPI.Method.credentialsLend)
        try control.ask(2, id: 1, DaemonAPI.Method.credentialsLend)
        try control.ask(2, id: 2, DaemonAPI.Method.agentsList)
        await eventually { control.lines(on: 1).count == 1 && control.lines(on: 2).count == 2 }

        #expect(control.lines(on: 1).first?.contains(#""ok":true"#) == true)
        #expect(control.lines(on: 2).allSatisfy { $0.contains(#""ok":true"#) })
        let lends = heard.all.filter { $0.method == DaemonAPI.Method.credentialsLend }
        #expect(Set(lends.map(\.role)) == [.control, .device])
        // The device's channel is that device, as the bridge would have made it.
        let list = heard.all.first { $0.method == DaemonAPI.Method.agentsList }
        #expect(list?.role == .device)
        #expect(list?.surface == .device(phone))
    }

    @Test func eachChannelHearsTheHostsBroadcastOnItsOwn() async throws {
        let dials = Dials()
        let (server, uplink) = host(heard: Heard(), dials: dials)
        defer { uplink.stop() }
        await eventually { !dials.all.isEmpty }
        try #require(!dials.all.isEmpty)
        let control = dials.all[0]
        try control.open(1)
        try control.open(2, device: UUID())
        await eventually { server.connectionCount == 2 }
        server.broadcast(DaemonAPI.Notification.agentChanged, ["x": 1])
        await eventually { control.lines(on: 1).count == 1 && control.lines(on: 2).count == 1 }
    }

    @Test func closingAChannelEndsItsConnectionAndOnlyThatOne() async throws {
        let dials = Dials()
        let (server, uplink) = host(heard: Heard(), dials: dials)
        defer { uplink.stop() }
        await eventually { !dials.all.isEmpty }
        try #require(!dials.all.isEmpty)
        let control = dials.all[0]
        try control.open(1)
        try control.open(2)
        await eventually { server.connectionCount == 2 }
        try control.transport.write(line: ControlWire.close(1))
        await eventually { server.connectionCount == 1 }
        #expect(uplink.openChannels == [2])
    }

    @Test func itDialsAgainWhenTheControlPlaneGoesAndItsChannelsGoWithIt() async throws {
        let dials = Dials()
        let (server, uplink) = host(heard: Heard(), dials: dials)
        defer { uplink.stop() }
        await eventually { !dials.all.isEmpty }
        try #require(!dials.all.isEmpty)
        try dials.all[0].open(1)
        await eventually { server.connectionCount == 1 }
        dials.all[0].transport.close()
        await eventually { server.connectionCount == 0 }
        await eventually { dials.all.count == 2 }
        try #require(dials.all.count > 1)
        await eventually { dials.all[1].lines(on: 0).count == 1 }
    }

    /// `open` says no role: whatever word an older control plane puts in its `grant`,
    /// `device` included, the channel is a person's, a window's or that device's.
    @Test func nothingOnTheUplinkMakesAChannelAnAgentOrAStranger() async throws {
        let heard = Heard()
        let dials = Dials()
        let (_, uplink) = host(heard: heard, dials: dials)
        defer { uplink.stop() }
        await eventually { !dials.all.isEmpty }
        try #require(!dials.all.isEmpty)
        let control = dials.all[0]
        let phone = UUID()
        try control.transport.write(line: #"{"c":5,"open":{"grant":"agent","client":"x"}}"#)
        try control.transport.write(line: #"{"c":6,"open":{"grant":"device","client":"y","device":"\#(phone.uuidString)"}}"#)
        await eventually { uplink.openChannels == [5, 6] }
        try control.ask(5, id: 1, DaemonAPI.Method.daemonQuit)
        try control.ask(6, id: 1, DaemonAPI.Method.daemonQuit)
        await eventually { heard.all.count == 2 }
        #expect(Set(heard.all.map(\.role)) == [.control, .device])
        #expect(heard.all.contains { $0.surface == .device(phone) })
    }
}
