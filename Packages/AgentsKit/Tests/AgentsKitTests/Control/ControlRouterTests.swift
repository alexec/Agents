import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// A host's end of an uplink, answering every request on a channel with where it
/// arrived, and remembering what the control plane opened and closed.
final class FakeUplinkHost: @unchecked Sendable {
    let transport: PairedTransport
    private let lock = NSLock()
    private(set) var opened: [Int: ControlWire.ChannelOpen] = [:]
    private(set) var closed: [Int] = []
    private(set) var received: [(channel: Int, message: String)] = []
    private var task: Task<Void, Never>?

    init(transport: PairedTransport) {
        self.transport = transport
        task = Task { [weak self] in
            do {
                for try await line in transport.lines() { self?.hear(line) }
            } catch {}
        }
    }

    private func hear(_ line: String) {
        guard let frame = try? ControlWire.readHost(line) else { return }
        switch frame {
        case .open(let channel, let open):
            lock.withLock { opened[channel] = open }
        case .close(let channel):
            lock.withLock { closed.append(channel) }
        case .message(let channel, let message):
            lock.withLock { received.append((channel, message)) }
            if case .request(let id, let method, _)? = try? JSONRPCCodec.decode(line: message),
               let reply = try? JSONRPCCodec.encode(.success(id: id, result: ["channel": .int(channel), "method": .string(method)])) {
                try? transport.write(line: ControlWire.channel(channel, message: reply))
            }
        }
    }

    var openChannels: [Int] { lock.withLock { opened.keys.filter { !closed.contains($0) }.sorted() } }
    var allOpened: [Int: ControlWire.ChannelOpen] { lock.withLock { opened } }
    var closedChannels: [Int] { lock.withLock { closed } }
    var messages: [(channel: Int, message: String)] { lock.withLock { received } }

    /// Says something on one channel, as a host's broadcast does on each.
    func say(_ line: String, on channel: Int) {
        try? transport.write(line: ControlWire.channel(channel, message: line))
    }

    func stop() {
        transport.close()
        task?.cancel()
    }
}

/// A client's end: every line it hears, in order.
final class FakeControlClient: @unchecked Sendable {
    let transport: PairedTransport
    private let lock = NSLock()
    private var heard: [String] = []
    private var task: Task<Void, Never>?

    init(transport: PairedTransport) {
        self.transport = transport
        task = Task { [weak self] in
            do {
                for try await line in transport.lines() { self?.lock.withLock { self?.heard.append(line) } }
            } catch {}
        }
    }

    var lines: [String] { lock.withLock { heard } }

    func send(_ line: String) throws { try transport.write(line: line) }

    func request(_ id: Int, _ method: String, host: HostID?) throws {
        let message = try JSONRPCCodec.encode(.request(id: .number(id), method: method, params: nil))
        try send(ControlWire.wrap(host: host, message: message))
    }
}

struct StubControl: ControlHandling {
    func handles(_ method: String) -> Bool { method == DaemonAPI.Method.hostsList }
    func handle(method: String, params: JSONValue?, from caller: ControlRouter.Caller) async throws -> JSONValue {
        ["answeredBy": "control", "grant": .string(caller.grant.rawValue)]
    }
    func hostSaid(_ host: HostID, method: String, params: JSONValue?) async throws -> JSONValue { [:] }
}

func client(_ grant: Grant, id: UUID = UUID()) -> ClientRecord {
    ClientRecord(id: id, name: "test", kind: grant == .operator ? .mac : .iPhone, publicKey: Data(),
                 grant: grant, paired: Date())
}

@Suite("The control plane's router")
struct ControlRouterTests {
    let home = HostID(rawValue: "mac")
    let server = HostID(rawValue: "k3v9x0qa")

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

    @Test func aRequestReachesItsHostUntouchedAndTheReplyComesBackTagged() async throws {
        let router = ControlRouter(handler: StubControl(), homeHost: home)
        let host = await connectHost(router, server)
        let window = await connectClient(router, client(.operator))
        await eventually { host.openChannels.count == 1 }

        // Spacing and key order a re-encoding would not keep.
        let exact = #"{"method": "agents/list", "jsonrpc":"2.0", "id":7,  "params":{}}"#
        try window.send(ControlWire.wrap(host: server, message: exact))
        await eventually { !host.messages.isEmpty }
        #expect(host.messages.first?.message == exact)

        await eventually { !window.lines.isEmpty }
        guard case .toHost(let from, let reply)? = try? ControlWire.readClient(window.lines[0]) else {
            Issue.record("the reply came back untagged: \(window.lines)")
            return
        }
        #expect(from == server)
        #expect(reply.contains(#""method":"agents/list""#))
        host.stop()
    }

    @Test func eachClientHearsAHostsBroadcastOnceTaggedWithTheHost() async throws {
        let router = ControlRouter(handler: StubControl(), homeHost: home)
        let host = await connectHost(router, server)
        let a = await connectClient(router, client(.operator))
        let b = await connectClient(router, client(.device))
        // A client is wrapped from its first wrapped line, so each says hello first.
        try a.request(1, DaemonAPI.Method.ping, host: nil)
        try b.request(1, DaemonAPI.Method.ping, host: nil)
        await eventually { host.openChannels.count == 2 && a.lines.count == 1 && b.lines.count == 1 }

        let note = #"{"jsonrpc":"2.0","method":"agent/changed","params":{"x":1}}"#
        for channel in host.openChannels { host.say(note, on: channel) }
        await eventually { a.lines.count == 2 && b.lines.count == 2 }
        #expect(a.lines[1] == ControlWire.wrap(host: server, message: note))
        #expect(b.lines[1] == ControlWire.wrap(host: server, message: note))
        try await Task.sleep(for: .milliseconds(50))
        #expect(a.lines.count == 2)
        host.stop()
    }

    @Test func presenceFromAnyHostIsFoldedForNotices() async throws {
        let router = ControlRouter(handler: StubControl(), homeHost: home)
        let host = await connectHost(router, server)
        let window = await connectClient(router, client(.operator))
        let phoneID = UUID()
        let phone = await connectClient(router, client(.device, id: phoneID))
        await eventually { host.openChannels.count == 2 }

        let atMac = DaemonAPI.PresenceReport(watching: nil, active: true)
        let inHand = DaemonAPI.PresenceReport(watching: nil, active: true, mayNotify: true)
        let macLine = try JSONRPCCodec.encode(.request(id: .number(1), method: DaemonAPI.Method.presenceReport,
                                                       params: try JSONValue.encoding(atMac)))
        let phoneLine = try JSONRPCCodec.encode(.request(id: .number(2), method: DaemonAPI.Method.presenceReport,
                                                         params: try JSONValue.encoding(inHand)))
        try window.send(ControlWire.wrap(host: server, message: macLine))
        try phone.send(ControlWire.wrap(host: home, message: phoneLine))
        await eventually { await router.foldedPresences().count == 2 }

        let folded = await router.foldedPresences()
        #expect(folded[.mac]?.active == true)
        #expect(folded[.device(phoneID)]?.active == true)
        #expect(await router.notifyFlags()[phoneID] == true)
        host.stop()
    }

    /// Two tabs of one browser are two sockets of one client. The client is active while either
    /// is, whichever spoke last: a hidden tab must not mark the person away (071 R11, T052).
    @Test func aClientIsActiveWhileAnyOfItsSocketsIs() async throws {
        let router = ControlRouter(handler: StubControl(), homeHost: home)
        let host = await connectHost(router, home)
        let browser = client(.device)
        var tabs: [(session: UUID, client: FakeControlClient)] = []
        for _ in 0..<2 {
            let (ours, theirs) = PairedTransport.pair()
            tabs.append((await router.attachClient(browser, transport: ours), FakeControlClient(transport: theirs)))
        }
        await eventually { host.openChannels.count == 2 }
        func report(_ tab: FakeControlClient, active: Bool, id: Int) throws {
            let line = try JSONRPCCodec.encode(.request(id: .number(id), method: DaemonAPI.Method.presenceReport,
                                                        params: try JSONValue.encoding(
                                                            DaemonAPI.PresenceReport(watching: nil, active: active))))
            try tab.send(ControlWire.wrap(host: home, message: line))
        }
        try report(tabs[0].client, active: true, id: 1)
        await eventually { await router.foldedPresences()[.device(browser.id)]?.active == true }
        // The other tab, hidden, speaks later.
        try await Task.sleep(for: .milliseconds(20))
        try report(tabs[1].client, active: false, id: 2)
        try await Task.sleep(for: .milliseconds(100))
        #expect(await router.foldedPresences()[.device(browser.id)]?.active == true)

        // The active tab closes: what is left is the hidden one.
        await router.detachClient(tabs[0].session)
        #expect(await router.foldedPresences()[.device(browser.id)]?.active == false)
        await router.detachClient(tabs[1].session)
        #expect(await router.foldedPresences()[.device(browser.id)] == nil)
        host.stop()
    }

    @Test func aDeviceChannelIsOpenedAsThatDeviceAndAnOperatorsAsNone() async throws {
        let router = ControlRouter(handler: StubControl(), homeHost: home)
        let host = await connectHost(router, server)
        let phone = client(.device)
        _ = await connectClient(router, client(.operator))
        _ = await connectClient(router, phone)
        await eventually { host.allOpened.count == 2 }
        let opens = Array(host.allOpened.values)
        #expect(opens.contains { $0.grant == .device && $0.device == phone.id })
        #expect(opens.contains { $0.grant == .operator && $0.device == nil })
        host.stop()
    }

    @Test func anOfflineHostIsRefusedAtOnceAndAnUnknownOneByName() async throws {
        let router = ControlRouter(handler: StubControl(), knownHosts: [server], homeHost: home)
        let window = await connectClient(router, client(.operator))
        try window.request(1, DaemonAPI.Method.agentsList, host: server)
        try window.request(2, DaemonAPI.Method.agentsList, host: HostID(rawValue: "nobody"))
        await eventually { window.lines.count == 2 }
        #expect(window.lines.contains { $0.contains("\(DaemonAPI.Failure.hostOffline)") })
        #expect(window.lines.contains { $0.contains("\(DaemonAPI.Failure.noSuchHost)") })
    }

    /// An uplink that has ended but is not yet dropped takes no request: the client is
    /// told, rather than waiting on an answer that will never come (#62).
    @Test func aRequestTheUplinkWillNotTakeIsRefusedNotLost() async throws {
        let router = ControlRouter(handler: StubControl(), homeHost: home)
        let (ours, theirs) = PairedTransport.pair()
        await router.attachHost(server, transport: ours)
        let window = await connectClient(router, client(.operator))
        await eventually { await router.channels(of: server).count == 1 }
        ours.close()
        try window.request(1, DaemonAPI.Method.filesList, host: server)
        await eventually { !window.lines.isEmpty }
        #expect(window.lines.first?.contains("\(DaemonAPI.Failure.hostOffline)") == true)
        theirs.close()
    }

    @Test func aBareLineIsTheHomeHostsAndItsReplyComesBackBare() async throws {
        let router = ControlRouter(handler: StubControl(), homeHost: home)
        let host = await connectHost(router, home)
        let remote = await connectClient(router, client(.device))
        await eventually { host.openChannels.count == 1 }
        let bare = #"{"jsonrpc":"2.0","id":3,"method":"agents/list"}"#
        try remote.send(bare)
        await eventually { !remote.lines.isEmpty }
        #expect(host.messages.first?.message == bare)
        #expect(!remote.lines[0].hasPrefix(#"{"h""#))
        host.stop()
    }

    @Test func aBareLineForTheControlPlanesOwnMethodIsAnsweredThere() async throws {
        let router = ControlRouter(handler: StubControl(), homeHost: home)
        let host = await connectHost(router, home)
        let remote = await connectClient(router, client(.device))
        try remote.send(#"{"jsonrpc":"2.0","id":4,"method":"hosts/list"}"#)
        await eventually { !remote.lines.isEmpty }
        #expect(remote.lines[0].contains("control"))
        #expect(host.messages.isEmpty)
        host.stop()
    }

    @Test func forgettingAClientClosesEveryOneOfItsChannels() async throws {
        let router = ControlRouter(handler: StubControl(), homeHost: home)
        let a = await connectHost(router, home)
        let b = await connectHost(router, server)
        let phone = client(.device)
        _ = await connectClient(router, phone)
        _ = await connectClient(router, phone)
        await eventually { a.openChannels.count == 2 && b.openChannels.count == 2 }
        await router.forgetClient(phone.id)
        await eventually { a.openChannels.isEmpty && b.openChannels.isEmpty }
        #expect(await router.sessionCount == 0)
        a.stop(); b.stop()
    }

    /// Each of a forgotten client's sockets is told why it closes, so a browser deletes its
    /// key at once (071 FR-014); a client that merely leaves is closed plainly.
    @Test func aForgottenClientsSocketsCloseWith4403() async throws {
        let router = ControlRouter(handler: StubControl(), homeHost: home)
        let browser = client(.device)
        let tabs = [ClosingRecorder(), ClosingRecorder()]
        for tab in tabs { await router.attachClient(browser, transport: tab) }
        let other = ClosingRecorder()
        let session = await router.attachClient(client(.device), transport: other)
        await router.forgetClient(browser.id)
        #expect(tabs.map(\.closes) == [[4403], [4403]])
        await router.detachClient(session)
        #expect(other.closes == [nil])
    }

    @Test func channelNumbersAreNeverUsedTwiceOnOneUplink() async throws {
        let router = ControlRouter(handler: StubControl(), homeHost: home)
        let host = await connectHost(router, server)
        var seen: Set<Int> = []
        for _ in 0..<5 {
            let (ours, theirs) = PairedTransport.pair()
            let session = await router.attachClient(client(.operator), transport: ours)
            let expected = seen.count + 1
            await eventually { host.allOpened.count == expected }
            await router.detachClient(session)
            theirs.close()
            seen = Set(host.allOpened.keys)
        }
        #expect(seen.count == 5)
        host.stop()
    }

    @Test func aHostComingOnlineOpensAChannelForEveryClientAlreadyThere() async throws {
        let router = ControlRouter(handler: StubControl(), homeHost: home)
        _ = await connectClient(router, client(.operator))
        _ = await connectClient(router, client(.device))
        let host = await connectHost(router, server)
        await eventually { host.openChannels.count == 2 }
        host.stop()
    }

    @Test func aHostGoingAwayIsToldToEveryWrappedClient() async throws {
        let router = ControlRouter(handler: StubControl(), homeHost: home)
        let host = await connectHost(router, server)
        let window = await connectClient(router, client(.operator))
        try window.request(1, DaemonAPI.Method.ping, host: nil)
        await eventually { window.lines.count == 1 }
        host.stop()
        await eventually { window.lines.contains { $0.contains(DaemonAPI.Notification.controlHostChanged) && $0.contains("offline") } }
        #expect(await router.state(of: server)?.isOnline == false)
    }

    @Test func changingAGrantReopensTheChannelsWithTheNewOne() async throws {
        let router = ControlRouter(handler: StubControl(), homeHost: home)
        let host = await connectHost(router, server)
        let phone = client(.device)
        let remote = await connectClient(router, phone)
        await eventually { host.openChannels.count == 1 }
        try remote.request(1, DaemonAPI.Method.credentialsLend, host: server)
        await eventually { remote.lines.count == 1 }
        #expect(remote.lines[0].contains("\(DaemonAPI.Failure.notPermitted)"))

        await router.setGrant(.operator, of: phone.id)
        await eventually { host.openChannels.count == 1 && host.closedChannels.count == 1 }
        let reopened = host.openChannels[0]
        #expect(host.allOpened[reopened]?.grant == .operator)
        try remote.request(2, DaemonAPI.Method.credentialsLend, host: server)
        await eventually { remote.lines.count == 2 }
        #expect(remote.lines[1].contains(DaemonAPI.Method.credentialsLend))
        host.stop()
    }
}

/// A client transport that remembers how it was closed: nil for plainly, else the code.
final class ClosingRecorder: LineTransport, ReasonedClose, @unchecked Sendable {
    private let base: PairedTransport
    private let lock = NSLock()
    private var closed: [UInt16?] = []

    init() { base = PairedTransport.pair().0 }

    var closes: [UInt16?] { lock.withLock { closed } }
    func write(line: String) throws {}
    func lines() -> AsyncThrowingStream<String, any Error> { base.lines() }
    func close() { lock.withLock { closed.append(nil) } }
    func close(code: UInt16, reason: String) { lock.withLock { closed.append(code) } }
}
