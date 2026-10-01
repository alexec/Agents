import AgentsKit
import AgentsKitCore
import ControlDial
@testable import ControlPlaneKit
import Foundation
import Testing

/// The relay host and notices through it (058, T096–T097): `agents-relay` joined with a
/// host code, a fake iCloud between it and a device, and one copy of the service.
@Suite("Notices and devices through the relay host", .serialized, .timeLimit(.minutes(2)))
struct NoticesTests {
    let base = ControlServiceTests()
    var control: (privateKey: Data, publicKey: Data) { base.control }

    struct Relay {
        let relay: ControlRelay
        let host: HostID
        let mailbox: FakeMailbox
        let cloud: FakeRelayCloud
    }

    /// `agents-relay` on a fake iCloud, joined with a host code.
    func relay(_ running: ControlServiceTests.Running) async throws -> Relay {
        let files = ControlRelay.Files(folder: FileManager.default.temporaryDirectory
            .appendingPathComponent("relay-\(UUID().uuidString)", isDirectory: true))
        let code = try #require(ControlCode(text: try await running.service.codes.issue(.host).text))
        let membership = try await ControlRelay.enroll(code, files: files, name: "relay mac")
        let cloud = FakeRelayCloud()
        let mailbox = FakeMailbox()
        let relay = try ControlRelay(files: files, name: "relay mac", channel: FakeRelayChannel(cloud: cloud), mailbox: mailbox)
        await relay.start()
        let host = try #require(membership.host)
        await eventually { await running.service.router.state(of: host)?.isOnline == true }
        return Relay(relay: relay, host: host, mailbox: mailbox, cloud: cloud)
    }

    /// A device client paired by code, with the key it keeps.
    func device(_ running: ControlServiceTests.Running) async throws -> (UUID, Data, ControlMembership) {
        let key = ControlAgreement.generate()
        let code = try #require(ControlCode(text: try await running.service.codes.issue(.client(.device)).text))
        let id = UUID()
        let membership = try await ControlCodeUse.pairClient(code, privateKey: key.privateKey, id: id, name: "phone",
                                                             kind: .iPhone, dial: ControlJoin.nio)
        return (id, key.privateKey, membership)
    }

    func need() -> Need {
        Need(id: .permission(UUID()), agentID: UUID(), folder: URL(filePath: "/work"), kind: .permission,
             raisedAt: Date().addingTimeInterval(-600),
             headline: Headline(h1: "work", h2: "Fix the test", h3: "may run a command"))
    }

    @Test func theRelayHostRunsNothingAndIsNamedForDevices() async throws {
        let running = try await base.start()
        defer { Task { await running.service.stop() } }
        let relay = try await relay(running)
        defer { relay.relay.stop() }
        let (_, link) = try await base.client(at: running.url, code: try await running.service.codes.issue(.client(.operator)).text)
        defer { link.disconnect() }
        let control = DaemonClient(link: link.controlLink)
        try await control.connect(startIfNeeded: false)

        let hosts = try await control.call(DaemonAPI.Method.hostsList, returning: [DaemonAPI.ControlHost].self)
        #expect(hosts.first { $0.id == relay.host }?.relay == true)
        #expect(relay.host != .mac)
        let status = try await control.call(DaemonAPI.Method.controlStatus, returning: DaemonAPI.ControlStatus.self)
        #expect(status.relayKey == relay.relay.publicKey)
        #expect(status.homeHost != relay.host)
        // The window's session was given no channel on it.
        #expect(await running.service.router.channels(of: relay.host).isEmpty)

        // Switched off, it names no relay and still runs nothing for anyone.
        _ = try await control.call(DaemonAPI.Method.hostsSetRelay,
                                   try JSONValue.encoding(DaemonAPI.HostRelayRequest(host: relay.host, relay: false)))
        let after = try await control.call(DaemonAPI.Method.controlStatus, returning: DaemonAPI.ControlStatus.self)
        #expect(after.relayKey == nil)
        #expect(await running.service.router.channels(of: relay.host).isEmpty)
        #expect(await running.service.router.relayHeldHere() == nil)
        // A host that runs agents cannot be made one.
        let (host, uplink) = try await base.host(at: running.url, code: try await running.service.codes.issue(.host).text)
        defer { uplink.stop() }
        await #expect(throws: JSONRPCError.self) {
            _ = try await control.call(DaemonAPI.Method.hostsSetRelay,
                                       try JSONValue.encoding(DaemonAPI.HostRelayRequest(host: host, relay: true)))
        }
    }

    @Test func aNeedIsSealedToTheDeviceAndWithdrawn() async throws {
        let running = try await base.start()
        defer { Task { await running.service.stop() } }
        let (device, deviceKey, membership) = try await device(running)
        let (host, uplink) = try await base.host(at: running.url, code: try await running.service.codes.issue(.host).text)
        defer { uplink.stop() }
        await eventually { await running.service.router.state(of: host)?.isOnline == true }
        // The phone says it may be notified and is not in hand, as the Remote does.
        let phone = ControlLink(dial: try ControlCodeUse.clientDial(membership, privateKey: deviceKey, kind: "iphone",
                                                                    dial: ControlJoin.nio))
        defer { phone.disconnect() }
        let there = DaemonClient(link: phone.link(for: host))
        try await there.connect(startIfNeeded: false)
        _ = try await there.call(DaemonAPI.Method.presenceReport,
                                 try JSONValue.encoding(DaemonAPI.PresenceReport(watching: nil, active: false, mayNotify: true)))

        // No relay host yet: the need goes nowhere but the host's own clients.
        let early = need()
        uplink.tell(DaemonAPI.Method.attentionNeed, try JSONValue.encoding(DaemonAPI.AttentionNeed.offer(early, buzz: true)))
        try await Task.sleep(for: .milliseconds(300))

        let relay = try await relay(running)
        defer { relay.relay.stop() }
        #expect(await relay.mailbox.posted.isEmpty)

        let asked = need()
        uplink.tell(DaemonAPI.Method.attentionNeed, try JSONValue.encoding(DaemonAPI.AttentionNeed.offer(asked, buzz: true)))
        await eventually { await !relay.mailbox.waiting(for: device).isEmpty }
        let item = try #require(await relay.mailbox.waiting(for: device).first)
        #expect(item.needID == asked.id)
        let envelope = try #require(item.envelope)
        let headline = try Envelope.open(envelope, with: try DeviceKey.software(privateKey: deviceKey))
        #expect(headline.h2 == "Fix the test")

        // Said again, it does not buzz twice.
        uplink.tell(DaemonAPI.Method.attentionNeed, try JSONValue.encoding(DaemonAPI.AttentionNeed.offer(asked, buzz: true)))
        try await Task.sleep(for: .milliseconds(300))
        #expect(await relay.mailbox.posted.count == 1)

        uplink.tell(DaemonAPI.Method.attentionNeed, try JSONValue.encoding(DaemonAPI.AttentionNeed.withdraw(asked.id)))
        await eventually { await relay.mailbox.waiting(for: device).first?.envelope == nil }
        #expect(await relay.mailbox.waiting(for: device).first?.envelope == nil)
    }

    @Test func aDeviceReachesTheControlPlaneThroughTheRelay() async throws {
        let running = try await base.start()
        defer { Task { await running.service.stop() } }
        let (device, deviceKey, membership) = try await device(running)
        let relay = try await relay(running)
        defer { relay.relay.stop() }
        let (host, uplink) = try await base.host(at: running.url, code: try await running.service.codes.issue(.host).text)
        defer { uplink.stop() }
        await eventually { await running.service.router.state(of: host)?.isOnline == true }

        let dial = try ControlCodeUse.relayedDial(membership, privateKey: deviceKey, relayKey: relay.relay.publicKey,
                                                  channel: FakeRelayChannel(cloud: relay.cloud))
        let wrapped = ControlLink(dial: dial)
        defer { wrapped.disconnect() }
        let control = DaemonClient(link: wrapped.controlLink)
        try await control.connect(startIfNeeded: false, timeout: .seconds(40))
        let status = try await control.call(DaemonAPI.Method.controlStatus, returning: DaemonAPI.ControlStatus.self)
        #expect(status.you == device)
        let there = DaemonClient(link: wrapped.link(for: host))
        try await there.connect(startIfNeeded: false, timeout: .seconds(40))
        let answer = try await there.call(DaemonAPI.Method.agentsList)
        #expect(answer["host"]?.stringValue == host.rawValue)
        #expect(answer["role"]?.stringValue == "device")
        // Frame N: an operator sees it come through the relay, and which Mac relays.
        let caller = ControlRouter.Caller(session: UUID(), client: UUID(), grant: .operator, kind: .mac)
        let links = try await running.service.methods.handle(method: DaemonAPI.Method.clientsConnections, params: nil, from: caller)
            .decode([DaemonAPI.ClientConnection].self)
        #expect(links.first { $0.client == device } == DaemonAPI.ClientConnection(client: device, relayed: true, through: "relay mac"))
        // Everything iCloud held was sealed: no line of the exchange is legible there.
        for record in await relay.cloud.stored(device: device) {
            #expect(!String(decoding: record.sealed, as: UTF8.self).contains("hello"))
        }
    }

    @Test func onlyADeviceMaySayItCameThroughTheRelay() async throws {
        let running = try await base.start()
        defer { Task { await running.service.stop() } }
        let (_, _, credentials) = try await base.pairedClient(at: running.url,
                                                              code: try await running.service.codes.issue(.client(.operator)).text)
        guard case .client(let id) = credentials.identity else { return }
        var relayed = credentials
        relayed.kind = "relay"
        relayed.relayingFor = id
        await #expect(throws: ControlAuth.Refusal.self) { _ = try await base.join(running.url, relayed) }
        // Nor for somebody else.
        let (device, deviceKey, membership) = try await device(running)
        let key = try ControlAuth.clientKey(privateKey: deviceKey, peer: membership.controlKey, client: device)
        let other = ControlAuth.Credentials(identity: .client(device), key: key, kind: "relay", controlKey: membership.controlKey,
                                            relayingFor: UUID())
        await #expect(throws: ControlAuth.Refusal.self) { _ = try await base.join(running.url, other) }
    }

    @Test func theDeskBuzzesOnceMovesAndWithdraws() async {
        let desk = NoticeDesk()
        let phone = Device(id: UUID(), publicKey: Data([1]), name: "Phone", kind: .iPhone,
                           announcedAt: Date().addingTimeInterval(-86_400), mayNotify: true)
        let asked = need()
        let first = await desk.heard(.offer(asked, buzz: true), presences: [:], devices: [phone])
        #expect(first.count == 1)
        #expect(first.first?.device == phone.id)
        #expect(first.first?.headline != nil)
        #expect(await desk.heard(.offer(asked, buzz: true), presences: [:], devices: [phone]).isEmpty)
        let gone = await desk.heard(.withdraw(asked.id), presences: [:], devices: [phone])
        #expect(gone.map(\.device) == [phone.id])
        #expect(gone.first?.headline == nil)
        #expect(await desk.heard(.withdraw(asked.id), presences: [:], devices: [phone]).isEmpty)
    }
}
