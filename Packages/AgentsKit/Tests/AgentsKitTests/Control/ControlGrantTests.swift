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
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("grants-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let methods = ControlMethods(store: GrantStore(root: root),
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
struct GrantStoreTests {
    func scratch() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("grant-store-\(UUID())")
    }

    @Test func clientsHostsAndSettingsSurviveARestart() throws {
        let root = scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = GrantStore(root: root)
        let window = client(.operator)
        let phone = client(.device)
        try store.saveClients([window, phone])
        try store.saveHosts([HostRecord(id: .mac, name: "This Mac", machineID: "m1"),
                             HostRecord(id: HostID(rawValue: "k3v9x0qa"), name: "devbox",
                                        reach: .ssh(destination: "agents@127.0.0.1", hostKeyFingerprint: nil))])
        try store.saveSettings(ControlSettings(name: "Alex's Mac", homeHost: .mac, machineID: "m1"))

        let again = GrantStore(root: root)
        #expect(Set(again.loadClients().map(\.id)) == [window.id, phone.id])
        #expect(again.loadClients().first { $0.id == phone.id }?.grant == .device)
        #expect(again.loadHosts().count == 2)
        #expect(again.loadHosts().first { $0.id.rawValue == "k3v9x0qa" }?.reach.isSSH == true)
        #expect(again.loadSettings()?.homeHost == .mac)
    }

    @Test func aDaemonsDevicesAreReadAsDeviceClientsWithTheirKeys() throws {
        let root = scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let key = Data((0..<65).map { UInt8($0) })
        let device = Device(id: UUID(), publicKey: key, name: "Alex's iPhone", kind: .iPhone,
                            announcedAt: Date(), mayNotify: true)
        let locations = StoreLocations(root: root)
        try DeviceStore(locations: locations).save([device])

        let clients = GrantStore.legacyDevices(at: locations.devices)
        #expect(clients.count == 1)
        #expect(clients[0].id == device.id)
        #expect(clients[0].publicKey == key)
        #expect(clients[0].grant == .device)
        #expect(clients[0].kind == .iPhone)
    }

    @Test func theLastOperatorCanBeNeitherDemotedNorForgotten() throws {
        let window = client(.operator)
        let phone = client(.device)
        let both = [window, phone]
        #expect(throws: JSONRPCError.self) { _ = try GrantStore.settingGrant(.device, of: window.id, in: both) }
        #expect(throws: JSONRPCError.self) { _ = try GrantStore.forgetting(window.id, in: both) }
        // With a second operator, either may go.
        let promoted = try GrantStore.settingGrant(.operator, of: phone.id, in: both)
        let demoted = try GrantStore.settingGrant(.device, of: window.id, in: promoted)
        #expect(demoted.filter { $0.grant == .operator }.map(\.id) == [phone.id])
        #expect(try GrantStore.forgetting(phone.id, in: both).count == 1)
    }

    @Test func anUnreadableFileIsNobody() throws {
        let root = scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: root.appendingPathComponent("clients.json"))
        #expect(GrantStore(root: root).loadClients().isEmpty)
    }
}
