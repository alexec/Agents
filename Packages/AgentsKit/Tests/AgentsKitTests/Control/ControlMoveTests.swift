import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// Moving today's set-up across (058, US6, T060).
@Suite("Moving a set-up to a control plane")
struct ControlMoveTests {
    func roots() throws -> (StoreLocations, URL) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("move-\(UUID().uuidString.prefix(6))")
        let locations = StoreLocations(root: base.appendingPathComponent("host"))
        try locations.createDirectories()
        return (locations, base.appendingPathComponent("control"))
    }

    func device(_ name: String) -> Device {
        Device(id: UUID(), publicKey: Data([0x04] + (0..<64).map { _ in UInt8.random(in: 0...255) }), name: name,
               kind: .iPhone, announcedAt: Date(), mayNotify: true)
    }

    @Test func pairedDevicesBecomeDeviceClientsWithTheirOwnKeys() throws {
        let (locations, control) = try roots()
        defer { try? FileManager.default.removeItem(at: control.deletingLastPathComponent()) }
        let phone = device("Alex's iPhone")
        try DeviceStore(locations: locations).save([phone])

        try ControlMove.prepare(control: control, from: locations)

        let clients = GrantStore(root: control).loadClients()
        #expect(clients.count == 1)
        #expect(clients[0].id == phone.id)
        #expect(clients[0].publicKey == phone.publicKey)
        #expect(clients[0].grant == .device)
        #expect(GrantStore(root: control).loadSettings()?.homeHost == .mac)
        // The old root is only read.
        #expect(DeviceStore(locations: locations).load().map(\.id) == [phone.id])
    }

    @Test func runningItAgainChangesNothing() throws {
        let (locations, control) = try roots()
        defer { try? FileManager.default.removeItem(at: control.deletingLastPathComponent()) }
        try DeviceStore(locations: locations).save([device("iPad")])
        try ControlMove.prepare(control: control, from: locations)
        let first = GrantStore(root: control).loadClients()
        try ControlMove.prepare(control: control, from: locations)
        #expect(GrantStore(root: control).loadClients() == first)
    }

    @Test func aControlRootWithClientsOfItsOwnIsRefused() throws {
        let (locations, control) = try roots()
        defer { try? FileManager.default.removeItem(at: control.deletingLastPathComponent()) }
        try GrantStore(root: control).saveClients([ClientRecord(id: UUID(), name: "Studio", kind: .mac,
                                                                publicKey: Data([1]), grant: .operator, paired: Date())])
        #expect(throws: ControlMove.Refusal.alreadyUsed) { try ControlMove.prepare(control: control, from: locations) }
    }

    @Test func theWindowsServersAreKeptRenamedNotDeleted() throws {
        let (locations, control) = try roots()
        defer { try? FileManager.default.removeItem(at: control.deletingLastPathComponent()) }
        var list = HostList()
        try list.add(ServerHost(sshName: "agents@127.0.0.1:2222"))
        try HostStore(locations: locations).save(list)
        #expect(ControlMove.servers(of: locations).map(\.sshName) == ["agents@127.0.0.1:2222"])
        #expect(ControlMove.summary(of: locations).servers == ["127.0.0.1"])

        try ControlMove.retireServers(of: locations)
        #expect(!FileManager.default.fileExists(atPath: locations.hosts.path))
        #expect(FileManager.default.fileExists(atPath: locations.hosts.appendingPathExtension("moved").path))
        #expect(ControlMove.servers(of: locations).isEmpty)
    }
}
