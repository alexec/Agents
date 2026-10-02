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

    func records(_ control: URL) async throws -> ControlRecords {
        let records = ControlRecords(store: FolderStore(root: control.appendingPathComponent("store", isDirectory: true)))
        try await records.load()
        return records
    }

    /// What `agents-control move` does: the copy's store, with settings of its own.
    func prepare(_ control: URL, from locations: StoreLocations) async throws {
        let records = try await records(control)
        _ = try await records.settings(orMake: { ControlSettings(name: "Studio", machineID: "test") })
        try await ControlMove.prepare(records, from: locations)
    }

    @Test func pairedDevicesBecomeDeviceClientsWithTheirOwnKeys() async throws {
        let (locations, control) = try roots()
        defer { try? FileManager.default.removeItem(at: control.deletingLastPathComponent()) }
        let phone = device("Alex's iPhone")
        try DeviceStore(locations: locations).save([phone])

        try await prepare(control, from: locations)

        let clients = try await records(control).clients
        try #require(clients.count == 1)
        #expect(clients[0].id == phone.id)
        #expect(clients[0].publicKey == phone.publicKey)
        #expect(clients[0].kind == .iPhone)
        #expect(try await records(control).settings?.homeHost == .mac)
        // The old root is only read.
        #expect(DeviceStore(locations: locations).load().map(\.id) == [phone.id])
    }

    @Test func runningItAgainChangesNothing() async throws {
        let (locations, control) = try roots()
        defer { try? FileManager.default.removeItem(at: control.deletingLastPathComponent()) }
        try DeviceStore(locations: locations).save([device("iPad")])
        try await prepare(control, from: locations)
        let first = try await records(control).clients
        try await prepare(control, from: locations)
        #expect(try await records(control).clients == first)
    }

    @Test func aControlRootWithClientsOfItsOwnIsRefused() async throws {
        let (locations, control) = try roots()
        defer { try? FileManager.default.removeItem(at: control.deletingLastPathComponent()) }
        try await records(control).save(ClientRecord(id: UUID(), name: "Studio", kind: .mac,
                                                     publicKey: Data([1]), paired: Date()))
        await #expect(throws: ControlMove.Refusal.alreadyUsed) { try await prepare(control, from: locations) }
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

    /// Into the store a running `agents-control` serves (058, T084): its settings are the
    /// copy's and stay so, the devices keep their keys, and this Mac's host is home.
    @Test func theStoreACopyServesGetsTheDevices() async throws {
        let (locations, _) = try roots()
        let phone = device("Alex's iPhone")
        try DeviceStore(locations: locations).save([phone])
        let store = MemoryStore()
        let records = ControlRecords(store: store)
        let key = Data((0..<65).map { _ in UInt8.random(in: 0...255) })
        _ = try await records.settings(orMake: { ControlSettings(name: "mini", machineID: "m", url: "https://mini.local:8791", controlKey: key) })

        try await ControlMove.prepare(records, from: locations)

        let fresh = ControlRecords(store: store)
        try await fresh.load()
        #expect(await fresh.clients.map(\.id) == [phone.id])
        #expect(await fresh.clients.first?.publicKey == phone.publicKey)
        #expect(await fresh.settings?.homeHost == .mac)
        #expect(await fresh.settings?.controlKey == key)
        #expect(await fresh.settings?.url == "https://mini.local:8791")
    }

    /// A move that fails leaves the old root as it was (FR-039): nothing written to it,
    /// its devices and servers where they were, and nothing to tell a device.
    @Test func aFailedMoveLeavesTheOldRootWorking() async throws {
        let (locations, control) = try roots()
        defer { try? FileManager.default.removeItem(at: control.deletingLastPathComponent()) }
        let phone = device("iPad")
        try DeviceStore(locations: locations).save([phone])
        var list = HostList()
        try list.add(ServerHost(sshName: "agents@127.0.0.1:2222"))
        try HostStore(locations: locations).save(list)
        let before = try FileManager.default.contentsOfDirectory(atPath: locations.root.path).sorted()
        let devicesBefore = try Data(contentsOf: locations.devices)
        try await records(control).save(ClientRecord(id: UUID(), name: "Studio", kind: .mac,
                                                     publicKey: Data([1]), paired: Date()))

        await #expect(throws: ControlMove.Refusal.alreadyUsed) { try await prepare(control, from: locations) }

        #expect(try FileManager.default.contentsOfDirectory(atPath: locations.root.path).sorted() == before)
        #expect(try Data(contentsOf: locations.devices) == devicesBefore)
        #expect(ControlMove.servers(of: locations).map(\.sshName) == ["agents@127.0.0.1:2222"])
        #expect(!FileManager.default.fileExists(atPath: locations.controlMoved.path))
    }
}
