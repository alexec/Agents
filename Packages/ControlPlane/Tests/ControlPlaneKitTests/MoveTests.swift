import AgentsKit
import AgentsKitCore
import ControlDial
@testable import ControlPlaneKit
import Foundation
import Testing

/// The move, against a running control plane (058, US7, T087): a device paired the old way
/// proves itself as `c:` with the key it already had, and a code's command is what a
/// server runs to join.
@Suite("Moving a set-up to a running control plane", .timeLimit(.minutes(2)))
struct MoveTests {
    let base = ControlServiceTests()

    @Test func aMovedDeviceConnectsWithItsOwnKey() async throws {
        let store = MemoryStore()
        let running = try await base.start(store: store)
        defer { Task { await running.service.stop() } }

        // An old root with a phone paired the old way, its key its own.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mv-\(UUID().uuidString.prefix(6))")
        defer { try? FileManager.default.removeItem(at: root) }
        let locations = StoreLocations(root: root)
        try locations.createDirectories()
        let phoneKey = DeviceKey.ephemeral()
        let phone = Device(id: UUID(), publicKey: phoneKey.publicKey, name: "Alex's iPhone", kind: .iPhone,
                           announcedAt: Date(), mayNotify: true)
        try DeviceStore(locations: locations).save([phone])

        // What `agents-control move --from` does, into the store the copy serves.
        let records = ControlRecords(store: store)
        try await records.load()
        try await ControlMove.prepare(records, from: locations)

        // The phone, told where the control plane is, dials as itself.
        let shared = try phoneKey.controlClientKey(controlKey: base.control.publicKey, client: phone.id)
        let membership = ControlMembership(client: phone.id, controlKey: base.control.publicKey, addresses: [], name: "test",
                                           url: running.url.absoluteString, pin: nil)
        let dial = try ControlCodeUse.clientDial(membership, sharedKey: shared, kind: "iphone", dial: ControlJoin.nio)
        let link = ControlLink(dial: dial)
        defer { link.disconnect() }
        let control = DaemonClient(link: link.controlLink)
        try await control.connect(startIfNeeded: false)
        let status = try await control.call(DaemonAPI.Method.controlStatus, returning: DaemonAPI.ControlStatus.self)
        #expect(status.you == phone.id)
        #expect(status.homeHost == .mac)
        // And, as every client may since #111, it lists the control plane's clients.
        let clients = try await control.call(DaemonAPI.Method.clientsList, returning: [ClientRecord].self)
        #expect(clients.contains { $0.id == phone.id })

        // Another key under its id is refused.
        let other = try DeviceKey.ephemeral().controlClientKey(controlKey: base.control.publicKey, client: phone.id)
        await #expect(throws: ControlAuth.Refusal.self) {
            _ = try await ControlCodeUse.clientDial(membership, sharedKey: other, kind: "iphone", dial: ControlJoin.nio)()
        }
    }

    @Test func aHostCodesCommandCarriesTheAddressAndPin() {
        let command = HostInstallScript.command(url: "https://mini.local:8791", pin: "abc-_", code: "agents-control:2:h:x")
        #expect(command.contains("https://mini.local:8791/v1/install.sh"))
        #expect(command.contains("--pinnedpubkey sha256//abc+/"))
        #expect(command.hasSuffix("sh -s -- 'agents-control:2:h:x'"))
    }
}
