import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// What crosses the control plane is bounded (#167): a host says a broadcast once for every
/// channel that hears it, the control plane copies it only to those, and a reader that
/// falls behind is closed rather than queued for without end.
@Suite("Backpressure on the control plane", .timeLimit(.minutes(1)))
struct BackpressureTests {
    let home = HostID(rawValue: "mac")
    let server = HostID(rawValue: "k3v9x0qa")

    // MARK: The wire

    @Test func aFanOutFrameReadsBackOnTheFastPathAndParsed() throws {
        let message = #"{"jsonrpc":"2.0","method":"agent/changed","params":{"x":[1,2]}}"#
        let line = ControlWire.fanOut([3, 1, 7], message: message)
        #expect(line == #"{"f":[3,1,7],"m":"# + message + "}")
        #expect(try ControlWire.readHost(line) == .fanOut(channels: [3, 1, 7], message: message))
        // Laid out another way, it is parsed whole.
        let spaced = #"{ "m": {"jsonrpc":"2.0","method":"x"}, "f": [2, 4] }"#
        guard case .fanOut(let channels, let parsed) = try ControlWire.readHost(spaced) else {
            Issue.record("not read as a fan-out frame")
            return
        }
        #expect(channels == [2, 4])
        #expect(parsed.contains(#""method":"x""#))
        // Channel 0 is the host's own; nothing fans out to it.
        #expect(throws: (any Error).self) { try ControlWire.readHost(#"{"f":[0,1],"m":{}}"#) }
    }

    @Test func answeredIDReadsOnlyTheTopLevel() {
        #expect(ControlRouter.answeredID(#"{"id":7,"jsonrpc":"2.0","result":{"id":9}}"#) == .number(7))
        #expect(ControlRouter.answeredID(#"{"jsonrpc":"2.0","result":{"id":9,"method":"no"},"id":"a\"b"}"#) == .string("a\"b"))
        #expect(ControlRouter.answeredID(#"{"jsonrpc":"2.0","error":{"code":1,"message":"}"},"id":-2}"#) == .number(-2))
        // A request the host makes of the client, and a notification: no reply in either.
        #expect(ControlRouter.answeredID(#"{"id":3,"method":"ask","params":{}}"#) == nil)
        #expect(ControlRouter.answeredID(#"{"method":"agent/changed","params":{"id":4}}"#) == nil)
        #expect(ControlRouter.answeredID(#"{"result":[1,{"id":5}]}"#) == nil)
    }

    @Test func boundedLinesSaysWhenTheBacklogPassesItsLimitAndWhenItFalls() async throws {
        final class Marks: @unchecked Sendable {
            let lock = NSLock()
            var high = 0
            var low = 0
        }
        let marks = Marks()
        let lines = BoundedLines(high: 10, low: 5, onHigh: { marks.lock.withLock { marks.high += 1 } },
                                 onLow: { marks.lock.withLock { marks.low += 1 } })
        // One line larger than the limit, with nothing waiting, is not a backlog.
        lines.yield(String(repeating: "a", count: 20))
        #expect(marks.lock.withLock { marks.high } == 0)
        lines.yield("bbbbb")
        #expect(marks.lock.withLock { marks.high } == 1)
        lines.yield("ccccc")
        #expect(marks.lock.withLock { marks.high } == 1)
        #expect(lines.bytesWaiting == 30)
        var iterator = lines.lines.makeAsyncIterator()
        _ = try await iterator.next()
        #expect(marks.lock.withLock { marks.low } == 0)
        _ = try await iterator.next()
        #expect(marks.lock.withLock { marks.low } == 1)
        #expect(lines.bytesWaiting == 5)
    }

    // MARK: The router

    func connectHost(_ router: ControlRouter, _ id: HostID) async -> FakeUplinkHost {
        let (ours, theirs) = PairedTransport.pair()
        await router.attachHost(id, transport: ours)
        return FakeUplinkHost(transport: theirs)
    }

    func connectClient(_ router: ControlRouter, _ record: ClientRecord) async -> FakeControlClient {
        let (ours, theirs) = PairedTransport.pair()
        await router.attachClient(record, transport: ours)
        return FakeControlClient(transport: theirs)
    }

    @Test func everyChannelIsOpenedForFanOut() async throws {
        let router = ControlRouter(handler: StubControl(), homeHost: home)
        let host = await connectHost(router, server)
        _ = await connectClient(router, client(.mac))
        _ = await connectClient(router, client(.iPhone))
        await eventually { host.openChannels.count == 2 }
        #expect(host.allOpened.values.allSatisfy { $0.fanOut == true })
        host.stop()
    }

    @Test func aFanOutReachesOnlyTheChannelsItNames() async throws {
        let router = ControlRouter(handler: StubControl(), homeHost: home)
        let host = await connectHost(router, server)
        var made: [FakeControlClient] = []
        for _ in 0..<3 {
            let one = await connectClient(router, client(.iPhone))
            try one.request(1, DaemonAPI.Method.ping, host: nil)
            made.append(one)
        }
        let clients = made
        await eventually { host.openChannels.count == 3 && clients.allSatisfy { !$0.lines.isEmpty } }
        let channels = await clientChannels(router)
        try #require(channels.count == 3)
        // Only what the host said: the control plane's own news (clientChanged) is not counted.
        let fromHost: @Sendable (FakeControlClient) -> [String] = { client in client.lines.filter { $0.hasPrefix(#"{"h":"k3v9x0qa""#) } }

        let note = #"{"jsonrpc":"2.0","method":"agent/entry","params":{"agent":"a"}}"#
        // The first and the last are watching; the middle one is not.
        try host.transport.write(line: ControlWire.fanOut([channels[0], channels[2], 999], message: note))
        await eventually { fromHost(clients[0]).count == 1 && fromHost(clients[2]).count == 1 }
        // And one more for all three, so the middle one has had time to hear the first.
        try host.transport.write(line: ControlWire.fanOut(channels, message: note))
        await eventually { fromHost(clients[1]).count == 1 && fromHost(clients[0]).count == 2 && fromHost(clients[2]).count == 2 }
        #expect(clients.map { fromHost($0).count } == [2, 1, 2])
        #expect(fromHost(clients[0]).first == ControlWire.wrap(host: server, message: note))
        host.stop()
    }

    /// The channel each client's session has on `server`, in the order they connected.
    func clientChannels(_ router: ControlRouter) async -> [Int] {
        await router.channels(of: server)
    }

    @Test func aBareClientOfTheHomeHostHearsAFanOutUnwrapped() async throws {
        let router = ControlRouter(handler: StubControl(), homeHost: home)
        let host = await connectHost(router, home)
        let remote = await connectClient(router, client(.iPhone))
        await eventually { host.openChannels.count == 1 }
        let note = #"{"jsonrpc":"2.0","method":"agent/changed","params":{}}"#
        try host.transport.write(line: ControlWire.fanOut(host.openChannels, message: note))
        await eventually { remote.lines == [note] }
        host.stop()
    }

    @Test func aClientWhoseTransportGivesUpIsDetachedAndItsChannelClosed() async throws {
        final class GivesUp: LineTransport, @unchecked Sendable {
            let base = PairedTransport.pair().0
            func write(line: String) throws { throw JSONRPCTransportError.closed }
            func lines() -> AsyncThrowingStream<String, any Error> { base.lines() }
            func close() {}
        }
        let router = ControlRouter(handler: StubControl(), homeHost: home)
        let host = await connectHost(router, home)
        await router.attachClient(client(.iPhone), transport: GivesUp())
        let other = await connectClient(router, client(.iPhone))
        await eventually { host.openChannels.count == 2 }
        let note = #"{"jsonrpc":"2.0","method":"agent/changed","params":{}}"#
        try host.transport.write(line: ControlWire.fanOut(host.openChannels, message: note))
        await eventually { await router.sessionCount == 1 && host.closedChannels.count == 1 }
        await eventually { other.lines == [note] }
        host.stop()
    }

    // MARK: The host

    @Test func aBroadcastGoesUpTheUplinkOnceNamingEveryChannelThatHearsIt() async throws {
        let dials = ControlUplinkTests.Dials()
        let (server, uplink) = ControlUplinkTests().host(heard: ControlUplinkTests.Heard(), dials: dials)
        defer { uplink.stop() }
        await eventually { !dials.all.isEmpty }
        try #require(!dials.all.isEmpty)
        let control = dials.all[0]
        for channel in 1...3 {
            try control.transport.write(line: ControlWire.open(channel, .init(client: UUID().uuidString, fanOut: true)))
        }
        // One from an older control plane, which is written to on its own.
        try control.transport.write(line: ControlWire.open(4, .init(client: UUID().uuidString)))
        await eventually { server.connectionCount == 4 }

        server.broadcast(DaemonAPI.Notification.agentChanged, ["x": 1])
        await eventually { fanOuts(control).count == 1 && control.lines(on: 4).count == 1 }
        #expect(fanOuts(control).first?.0 == [1, 2, 3])
        for channel in 1...3 { #expect(control.lines(on: channel).isEmpty) }
    }

    @Test func anAddressedBroadcastNamesOnlyWhoItIsFor() async throws {
        let dials = ControlUplinkTests.Dials()
        let heard = ControlUplinkTests.Heard()
        let (server, uplink) = ControlUplinkTests().host(heard: heard, dials: dials)
        defer { uplink.stop() }
        await eventually { !dials.all.isEmpty }
        try #require(!dials.all.isEmpty)
        let control = dials.all[0]
        let phone = UUID()
        try control.transport.write(line: ControlWire.open(1, .init(client: UUID().uuidString, fanOut: true)))
        try control.transport.write(line: ControlWire.open(2, .init(client: phone.uuidString, device: phone, fanOut: true)))
        await eventually { server.connectionCount == 2 }

        server.broadcast("shell/output", ["x": 1], to: { $0.surface == .device(phone) })
        await eventually { fanOuts(control).count == 1 }
        #expect(fanOuts(control).first?.0 == [2])
    }

    func fanOuts(_ control: ControlUplinkTests.FakeControlEnd) -> [([Int], String)] {
        control.lines.compactMap {
            if case .fanOut(let channels, let message)? = try? ControlWire.readHost($0) { return (channels, message) }
            return nil
        }
    }

    /// A connection that reads, but too slowly, is closed once its backlog passes the
    /// limit, instead of the daemon queueing for it without end.
    @Test func aConnectionTooFarBehindIsClosed() async throws {
        final class Stuck: LineTransport, @unchecked Sendable {
            let gate = DispatchSemaphore(value: 0)
            let (base, other) = PairedTransport.pair()
            func write(line: String) throws { gate.wait() }
            func lines() -> AsyncThrowingStream<String, any Error> { base.lines() }
            func close() { base.close(); other.close(); gate.signal() }
        }
        let server = DaemonServer(url: URL(fileURLWithPath: "/tmp/unused-\(UUID()).sock"), backlogLimit: 10_000) { _, _, _ in
            .success([:])
        }
        let stuck = Stuck()
        server.acceptVirtual(stuck, device: nil)
        await eventually { server.connectionCount == 1 }
        let pad = String(repeating: "x", count: 1_000)
        for _ in 0..<30 { server.broadcast(DaemonAPI.Notification.agentChanged, ["pad": .string(pad)]) }
        await eventually { server.connectionCount == 0 }
        // Let the blocked write go, so its queue ends.
        for _ in 0..<40 { stuck.gate.signal() }
    }
}
