import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// SC-005: every call only an operator may make is refused for a device by the control
/// plane, before a host hears of it.
@Suite("Grants at the control plane")
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

    static var refusedToDevices: [String] { everyMethod.filter { !ConnectionRole.device.allows($0) } }

    @Test func theListOfMethodsWasFound() {
        #expect(Self.everyMethod.count > 100)
        #expect(Self.refusedToDevices.contains(DaemonAPI.Method.credentialsLend))
    }

    @Test func everyOperatorOnlyMethodIsRefusedToADeviceBeforeTheHost() async throws {
        let server = HostID(rawValue: "k3v9x0qa")
        let router = ControlRouter(handler: StubControl(), homeHost: server)
        let (up, hostEnd) = PairedTransport.pair()
        await router.attachHost(server, transport: up)
        let host = FakeUplinkHost(transport: hostEnd)
        let (ours, theirs) = PairedTransport.pair()
        await router.attachClient(client(.device), transport: ours)
        let phone = FakeControlClient(transport: theirs)
        await eventually { host.openChannels.count == 1 }

        let refused = Self.refusedToDevices
        for (index, method) in refused.enumerated() {
            try phone.request(index + 1, method, host: server)
        }
        await eventually { phone.lines.count == refused.count }
        #expect(host.messages.isEmpty, "a host heard \(host.messages.map(\.message))")
        let notPermitted = phone.lines.filter { $0.contains("\(DaemonAPI.Failure.notPermitted)") }
        #expect(notPermitted.count == refused.count)
        host.stop()
    }

    @Test func whatADeviceMayDoStillReachesTheHost() async throws {
        let server = HostID(rawValue: "k3v9x0qa")
        let router = ControlRouter(handler: StubControl(), homeHost: server)
        let (up, hostEnd) = PairedTransport.pair()
        await router.attachHost(server, transport: up)
        let host = FakeUplinkHost(transport: hostEnd)
        let (ours, theirs) = PairedTransport.pair()
        await router.attachClient(client(.device), transport: ours)
        let phone = FakeControlClient(transport: theirs)
        await eventually { host.openChannels.count == 1 }

        let allowed = Self.everyMethod.filter { ConnectionRole.device.allows($0) }
        for (index, method) in allowed.enumerated() { try phone.request(index + 1, method, host: server) }
        await eventually { host.messages.count == allowed.count }
        host.stop()
    }

    @Test func theControlPlanesOwnOperatorMethodsAreRefusedToADevice() async throws {
        let methods = ControlMethods(records: ControlRecords(store: MemoryStore()),
                                     settings: ControlSettings(name: "test", machineID: "m"), version: "1")
        let device = ControlRouter.Caller(session: UUID(), client: UUID(), grant: .device, kind: .iPhone)
        for method in [DaemonAPI.Method.clientsList, DaemonAPI.Method.clientsSetGrant, DaemonAPI.Method.clientsForget,
                       DaemonAPI.Method.clientsStartPairing, DaemonAPI.Method.hostsInstall, DaemonAPI.Method.hostsRemove,
                       DaemonAPI.Method.hostsStartEnroll, DaemonAPI.Method.devicesForget] {
            await #expect(throws: JSONRPCError.self) {
                _ = try await methods.handle(method: method, params: nil, from: device)
            }
        }
        // And what any client may ask.
        _ = try await methods.handle(method: DaemonAPI.Method.hostsList, params: nil, from: device)
        _ = try await methods.handle(method: DaemonAPI.Method.controlStatus, params: nil, from: device)
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
        let window = client(.operator)
        let phone = client(.device)
        try await records.save(window)
        try await records.save(phone)
        try await records.save(HostRecord(id: .mac, name: "This Mac", machineID: "m1"))
        _ = try await records.changeSettings { $0.homeHost = .mac }

        let again = ControlRecords(store: FolderStore(root: root))
        try await again.load()
        #expect(Set(await again.clients.map(\.id)) == [window.id, phone.id])
        #expect(await again.client(phone.id)?.grant == .device)
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
        #expect(clients.count == 1)
        #expect(clients[0].id == device.id)
        #expect(clients[0].publicKey == key)
        #expect(clients[0].grant == .device)
        #expect(clients[0].kind == .iPhone)
    }

    @Test func theLastOperatorCanBeNeitherDemotedNorForgotten() async throws {
        let records = ControlRecords(store: MemoryStore())
        let window = client(.operator)
        let phone = client(.device)
        try await records.save(window)
        try await records.save(phone)
        await #expect(throws: JSONRPCError.self) { try await records.setGrant(.device, of: window.id) }
        await #expect(throws: JSONRPCError.self) { try await records.forget(window.id) }
        // With a second operator, either may go.
        try await records.setGrant(.operator, of: phone.id)
        try await records.setGrant(.device, of: window.id)
        #expect(await records.clients.filter { $0.grant == .operator }.map(\.id) == [phone.id])
        try await records.forget(window.id)
        #expect(await records.clients.map(\.id) == [phone.id])
    }

    /// Rule 11: a forgotten client is a tombstone, which reads as absent everywhere.
    @Test func forgettingWritesATombstoneThatReadsAsAbsent() async throws {
        let store = MemoryStore()
        let records = ControlRecords(store: store)
        let window = client(.operator)
        let phone = client(.device)
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

    /// Two copies read the same client; the second to write loses and changes nothing
    /// (FR-008), even when the first wrote the record back to how it was (rule 10).
    @Test func aChangeMadeAgainstAStaleReadIsRefused() async throws {
        let store = MemoryStore()
        let a = ControlRecords(store: store)
        let window = client(.operator)
        let phone = client(.device)
        try await a.save(window)
        try await a.save(phone)
        let b = ControlRecords(store: store)
        try await b.load()
        try await a.setGrant(.operator, of: phone.id)
        try await a.setGrant(.device, of: phone.id)
        await #expect(throws: StoreError.conflict(key: ControlRecords.clientKey(phone.id))) {
            try await b.setGrant(.operator, of: phone.id)
        }
        try await b.load()
        #expect(await b.client(phone.id)?.grant == .device)
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
}
