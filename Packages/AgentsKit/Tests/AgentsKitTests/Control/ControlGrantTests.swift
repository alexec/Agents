import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// One grant for every paired client (#111): a phone, an iPad or a browser may do
/// everything the Mac's window may, at the control plane and on every host.
@Suite("One grant at the control plane")
struct ControlGrantTests {
    /// Every method the daemon answers, read from where they are declared, so a method
    /// added later is covered without anybody remembering to list it here.
    static let everyMethod: [String] = {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/AgentsKitCore/Daemon/DaemonAPI.swift")
        guard let text = try? String(contentsOf: source, encoding: .utf8),
              let start = text.range(of: "public enum Method {"),
              let end = text.range(of: "public enum Notification {") else { return [] }
        let body = text[start.upperBound..<end.lowerBound]
        let pattern = try! NSRegularExpression(pattern: #"static let \w+ = "([^"]+)""#)
        let range = NSRange(body.startIndex..., in: body)
        return pattern.matches(in: String(body), range: NSRange(location: 0, length: range.length)).compactMap {
            Range($0.range(at: 1), in: String(body)).map { String(String(body)[$0]) }
        }
    }()

    /// What a phone was refused before #111, by name: credentials, sign-in, folders
    /// outside a project, hosts, plugins, workflow approval, helper limits, quitting.
    static let wasOperatorOnly = [
        DaemonAPI.Method.credentialsLend, DaemonAPI.Method.runtimeAuthenticate, DaemonAPI.Method.filesBrowse,
        DaemonAPI.Method.filesWrite, DaemonAPI.Method.workflowsApprove, DaemonAPI.Method.pluginsApprove,
        DaemonAPI.Method.projectsAdd, DaemonAPI.Method.projectsSetHelperLimits, DaemonAPI.Method.daemonQuit,
    ]

    @Test func theListOfMethodsWasFound() {
        #expect(Self.everyMethod.count > 100)
        #expect(Set(Self.wasOperatorOnly).isSubset(of: Self.everyMethod))
    }

    @Test(arguments: [ClientRecord.Kind.iPhone, .iPad, .browser])
    func everyMethodFromAPhoneOrABrowserReachesTheHost(_ kind: ClientRecord.Kind) async throws {
        let server = HostID(rawValue: "k3v9x0qa")
        let router = ControlRouter(handler: StubControl(), homeHost: server)
        let (up, hostEnd) = PairedTransport.pair()
        await router.attachHost(server, transport: up)
        let host = FakeUplinkHost(transport: hostEnd)
        let (ours, theirs) = PairedTransport.pair()
        let paired = client(kind)
        await router.attachClient(paired, transport: ours)
        let phone = FakeControlClient(transport: theirs)
        await eventually { host.openChannels.count == 1 }
        // Bound to itself on the host, so presence is its own, and asking everything a window may.
        let open = try #require(host.allOpened.values.first)
        #expect(open.device == paired.id)
        #expect(open.grant == LegacyGrant.everything)

        let methods = Self.everyMethod
        for (index, method) in methods.enumerated() { try phone.request(index + 1, method, host: server) }
        await eventually { host.messages.count == methods.count }
        #expect(Set(host.messages.map(\.message).compactMap { ControlWire.request(in: $0)?.method }) == Set(methods))
        #expect(!phone.lines.contains { $0.contains("\(DaemonAPI.Failure.notPermitted)") })
        host.stop()
    }

    /// And on the host: a channel the control plane opens for a phone or a browser is
    /// that device's, and may ask what a window may. Only an agent's helper is held back.
    @Test func aDevicesConnectionMayAskWhatAWindowMay() {
        for method in Self.everyMethod {
            #expect(ConnectionRole.device.allows(method) == ConnectionRole.control.allows(method), "\(method)")
        }
        for method in Self.wasOperatorOnly {
            #expect(ConnectionRole.device.allows(method))
            #expect(!ConnectionRole.agent.allows(method))
        }
    }

    @Test(arguments: [ClientRecord.Kind.iPhone, .browser])
    func theControlPlanesOwnMethodsAnswerAPhoneOrABrowser(_ kind: ClientRecord.Kind) async throws {
        let records = ControlRecords(store: MemoryStore())
        var hooks = ControlMethods.Hooks(startPairing: { _ in ["text": "code"] }, startEnroll: { ["text": "code"] },
                                         install: { _ in ["name": "server"] })
        hooks.update = { _ in }
        let methods = ControlMethods(records: records, settings: ControlSettings(name: "test", machineID: "m"),
                                     version: "1", hooks: hooks)
        let caller = ControlRouter.Caller(session: UUID(), client: UUID(), kind: kind)
        let other = client(.iPad)
        try await methods.admit(other)
        try await records.save(HostRecord(id: HostID(rawValue: "k3v9x0qa"), name: "server"))
        let host: JSONValue = ["host": "k3v9x0qa"]

        _ = try await methods.handle(method: DaemonAPI.Method.clientsList, params: nil, from: caller)
        _ = try await methods.handle(method: DaemonAPI.Method.clientsStartPairing, params: nil, from: caller)
        _ = try await methods.handle(method: DaemonAPI.Method.clientsStopPairing, params: nil, from: caller)
        _ = try await methods.handle(method: DaemonAPI.Method.clientsConnections, params: nil, from: caller)
        _ = try await methods.handle(method: DaemonAPI.Method.hostsStartEnroll, params: nil, from: caller)
        _ = try await methods.handle(method: DaemonAPI.Method.hostsInstall, params: [:], from: caller)
        _ = try await methods.handle(method: DaemonAPI.Method.hostsUpdate, params: host, from: caller)
        _ = try await methods.handle(method: DaemonAPI.Method.hostsCheckAgain, params: host, from: caller)
        _ = try await methods.handle(method: DaemonAPI.Method.clientsForget,
                                     params: ["client": .string(other.id.uuidString)], from: caller)
        #expect(await records.client(other.id) == nil)
        _ = try await methods.handle(method: DaemonAPI.Method.hostsRemove, params: host, from: caller)
        #expect(await records.hosts.isEmpty)
    }

    /// An older window still has a grant picker; what it asks is refused in words.
    @Test func settingAGrantIsRefusedInWords() async throws {
        let methods = ControlMethods(records: ControlRecords(store: MemoryStore()),
                                     settings: ControlSettings(name: "test", machineID: "m"), version: "1")
        let caller = ControlRouter.Caller(session: UUID(), client: UUID(), kind: .mac)
        do {
            _ = try await methods.handle(method: DaemonAPI.Method.clientsSetGrant,
                                         params: ["client": .string(UUID().uuidString), "grant": "device"], from: caller)
            Issue.record("a grant was set")
        } catch let error as JSONRPCError {
            #expect(error.code == DaemonAPI.Failure.notSupported)
            #expect(error.message.contains("no grant to change"))
        }
    }
}

@Suite("The control plane's records")
struct ControlRecordsTests {
    func folder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("records-\(UUID())")
    }

    @Test func clientsHostsAndSettingsSurviveARestart() async throws {
        let root = folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let records = ControlRecords(store: FolderStore(root: root))
        let settings = try await records.settings { ControlSettings(name: "Alex's Mac", machineID: "m1") }
        #expect(settings.owner != nil)
        let window = client(.mac)
        let phone = client(.iPhone)
        try await records.save(window)
        try await records.save(phone)
        try await records.save(HostRecord(id: .mac, name: "This Mac", machineID: "m1"))
        _ = try await records.changeSettings { $0.homeHost = .mac }

        let again = ControlRecords(store: FolderStore(root: root))
        try await again.load()
        #expect(Set(await again.clients.map(\.id)) == [window.id, phone.id])
        #expect(await again.client(phone.id)?.owner == settings.owner)
        #expect(await again.hosts.map(\.id) == [.mac])
        #expect(await again.settings?.homeHost == .mac)
    }

    @Test func aDaemonsDevicesAreReadAsDeviceClientsWithTheirKeys() throws {
        let root = folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let key = Data((0..<65).map { UInt8($0) })
        let device = Device(id: UUID(), publicKey: key, name: "Alex's iPhone", kind: .iPhone,
                            announcedAt: Date(), mayNotify: true)
        let locations = StoreLocations(root: root)
        try DeviceStore(locations: locations).save([device])

        let clients = ControlRecords.legacyDevices(at: locations.devices)
        try #require(clients.count == 1)
        #expect(clients[0].id == device.id)
        #expect(clients[0].publicKey == key)
        #expect(clients[0].kind == .iPhone)
    }

    /// No client is kept back as the last that may change things (#111): Agents Host can
    /// always make another code, so any may go, the last one too.
    @Test func anyClientMayBeForgottenTheLastToo() async throws {
        let records = ControlRecords(store: MemoryStore())
        let window = client(.mac)
        let phone = client(.iPhone)
        try await records.save(window)
        try await records.save(phone)
        try await records.forget(window.id)
        #expect(await records.clients.map(\.id) == [phone.id])
        try await records.forget(phone.id)
        #expect(await records.clients.isEmpty)
    }

    /// Rule 11: a forgotten client is a tombstone, which reads as absent everywhere.
    @Test func forgettingWritesATombstoneThatReadsAsAbsent() async throws {
        let store = MemoryStore()
        let records = ControlRecords(store: store)
        let window = client(.mac)
        let phone = client(.iPhone)
        try await records.save(window)
        try await records.save(phone)
        try await records.forget(phone.id)
        let stored = try #require(try await store.get(ControlRecords.clientKey(phone.id)))
        let tombstone = try ControlRecords.decoder.decode(ClientRecord.self, from: stored.data)
        #expect(tombstone.forgotten == true)
        let elsewhere = ControlRecords(store: store)
        try await elsewhere.load()
        #expect(await elsewhere.client(phone.id) == nil)
        #expect(await elsewhere.clients.map(\.id) == [window.id])
    }

    /// A Remote keeps its id: a device forgotten and paired again is admitted over its
    /// tombstone, whether this copy forgot it or another did.
    @Test func aForgottenDevicePairsAgainUnderItsOwnID() async throws {
        let store = MemoryStore()
        let records = ControlRecords(store: store)
        let window = client(.mac)
        let phone = client(.iPhone)
        try await records.save(window)
        try await records.save(phone)
        try await records.forget(phone.id)

        let methods = ControlMethods(records: records, settings: ControlSettings(name: "test", machineID: "m"), version: "1")
        try await methods.admit(phone)
        #expect(await records.client(phone.id)?.forgotten != true)
        #expect(Set(await records.clients.map(\.id)) == [window.id, phone.id])

        // Another copy read the phone before it was forgotten here, so its write conflicts first.
        let elsewhere = ControlRecords(store: store)
        try await elsewhere.load()
        try await records.forget(phone.id)
        let there = ControlMethods(records: elsewhere, settings: ControlSettings(name: "test", machineID: "m"), version: "1")
        try await there.admit(phone)
        #expect(await elsewhere.client(phone.id) != nil)
    }

    /// Two copies read the same client; the second to write loses and changes nothing
    /// (FR-008), even when the first wrote the record back to how it was (rule 10).
    @Test func aChangeMadeAgainstAStaleReadIsRefused() async throws {
        let store = MemoryStore()
        let a = ControlRecords(store: store)
        let window = client(.mac)
        let phone = client(.iPhone)
        try await a.save(window)
        try await a.save(phone)
        let b = ControlRecords(store: store)
        try await b.load()
        var renamed = phone
        renamed.name = "renamed"
        try await a.save(renamed)
        try await a.save(phone)
        await #expect(throws: StoreError.conflict(key: ControlRecords.clientKey(phone.id))) {
            try await b.save(renamed)
        }
        try await b.load()
        #expect(await b.client(phone.id)?.name == phone.name)
    }

    @Test func twoCopiesStartingOnAnEmptyStoreAgreeOnOneSettings() async throws {
        let store = MemoryStore()
        let first = ControlRecords(store: store)
        let second = ControlRecords(store: store)
        async let one = first.settings { ControlSettings(name: "one", machineID: "m") }
        async let two = second.settings { ControlSettings(name: "two", machineID: "m") }
        let (x, y) = try await (one, two)
        #expect(x == y)
    }

    @Test func anUnreadableObjectIsNobody() async throws {
        let store = MemoryStore()
        _ = try await store.put(ControlRecords.clientsPrefix + "junk.json", Data("not json".utf8), when: .absent)
        let records = ControlRecords(store: store)
        try await records.load()
        #expect(await records.clients.isEmpty)
    }

    // MARK: A browser (071)

    @Test func aBrowserRecordRoundTripsAndAnOlderRecordStillReads() throws {
        let record = ClientRecord(id: UUID(), name: "Safari on Alex's MacBook", kind: .browser,
                                  publicKey: Data([4]), paired: Date(timeIntervalSince1970: 0))
        let decoded = try JSONDecoder().decode(ClientRecord.self, from: try JSONEncoder().encode(record))
        #expect(decoded.kind == .browser)
        let older = #"{"id":"6F1C2A3B-4D5E-4F60-8172-93A4B5C6D7E8","name":"iPhone","kind":"iPhone","publicKey":"BA==","grant":"device","paired":0,"rev":0}"#
        #expect(try JSONDecoder().decode(ClientRecord.self, from: Data(older.utf8)).kind == .iPhone)
    }

    /// A record from before #111 that says `grant: device` reads as a full client, and is
    /// written back as `operator`, which is what an older copy then reads.
    @Test func aDeviceGrantReadsAsAFullClientAndIsWrittenAsOperator() async throws {
        let store = MemoryStore()
        let id = UUID()
        let older = #"{"id":"\#(id.uuidString)","name":"iPhone","kind":"iPhone","publicKey":"BA==","grant":"device","paired":"2026-09-01T00:00:00.000Z","rev":1}"#
        _ = try await store.put(ControlRecords.clientKey(id), Data(older.utf8), when: .absent)
        let records = ControlRecords(store: store)
        try await records.load()
        let record = try #require(await records.client(id))
        #expect(record.kind == .iPhone)

        try await records.save(record)
        let written = try #require(try await store.get(ControlRecords.clientKey(id)))
        let object = try JSONDecoder().decode([String: JSONValue].self, from: written.data)
        #expect(object["grant"] == "operator")
    }

    @Test func aKindFromALaterBuildReadsAsUnknown() throws {
        let later = #"{"id":"6F1C2A3B-4D5E-4F60-8172-93A4B5C6D7E8","name":"x","kind":"watch","publicKey":"BA==","grant":"device","paired":0,"rev":0}"#
        #expect(try JSONDecoder().decode(ClientRecord.self, from: Data(later.utf8)).kind == .unknown)
    }
}
