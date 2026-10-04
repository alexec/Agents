import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// A store file that cannot be read is set aside, never written over (#171).
///
/// What this holds, for each whole-file store the review named: a torn or garbage file is
/// moved aside as `<name>.corrupt-<time>`, byte for byte; the store carries on empty;
/// the next save is whole (no temporary left, the file reads); and a file written by an
/// earlier build still loads.
@Suite("Unreadable stores are set aside", .timeLimit(.minutes(1)))
struct UnreadableStoresTests {
    private let fileManager = FileManager.default
    private let garbage = Data(#"{"days":{"2026-10-03":{"USD":1"#.utf8)

    private func temporary() throws -> StoreLocations {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("UnreadableStores-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        let locations = StoreLocations(root: root)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        return locations
    }

    private func asides(_ url: URL) -> [URL] {
        ((try? fileManager.contentsOfDirectory(at: url.deletingLastPathComponent(), includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix(url.lastPathComponent + ".corrupt-") }
    }

    private func temporaries(_ locations: StoreLocations) -> [String] {
        ((try? fileManager.contentsOfDirectory(atPath: locations.root.path)) ?? []).filter { $0.hasSuffix(".tmp") }
    }

    /// The file was moved aside whole, and nothing is in its place.
    private func expectSetAside(_ url: URL, holding bytes: Data) throws {
        let kept = asides(url)
        #expect(kept.count == 1, "\(url.lastPathComponent) set aside once")
        #expect(try Data(contentsOf: #require(kept.first)) == bytes, "byte for byte")
    }

    private func device(_ name: String, at seconds: TimeInterval = 0) -> Device {
        Device(id: UUID(), publicKey: Data([1, 2, 3]), name: name, kind: .iPhone,
               announcedAt: Date(timeIntervalSince1970: 1_800_000_000 + seconds))
    }

    // MARK: Devices

    @Test func devicesThatDoNotReadAreSetAsideNotForgotten() throws {
        let locations = try temporary()
        try garbage.write(to: locations.devices)
        let store = DeviceStore(locations: locations)

        #expect(store.load().isEmpty)
        try expectSetAside(locations.devices, holding: garbage)

        try store.save([device("Phone")])
        #expect(store.load().map(\.name) == ["Phone"])
        #expect(asides(locations.devices).count == 1, "the copy is never written over")
        #expect(temporaries(locations).isEmpty)
    }

    @Test func oneBadDeviceCostsThatDeviceAndTheFileIsKept() throws {
        let locations = try temporary()
        let good = try StoreCoding.encoder.encode([device("Phone"), device("iPad", at: 1)])
        var list = try #require(JSONSerialization.jsonObject(with: good) as? [Any])
        list.insert(["id": "not a uuid"], at: 1)
        let mixed = try JSONSerialization.data(withJSONObject: list)
        try mixed.write(to: locations.devices)

        let store = DeviceStore(locations: locations)
        #expect(store.load().map(\.name) == ["Phone", "iPad"])
        try expectSetAside(locations.devices, holding: mixed)
        // The file itself is clean now, so the next read copies nothing again.
        #expect(store.load().map(\.name) == ["Phone", "iPad"])
        #expect(asides(locations.devices).count == 1)
    }

    @Test func devicesAnEarlierBuildWroteStillLoad() throws {
        let locations = try temporary()
        // As a build before #171 wrote it: `.atomic`, the same encoder, no extra keys.
        try StoreCoding.encoder.encode([device("Phone")]).write(to: locations.devices, options: .atomic)
        #expect(DeviceStore(locations: locations).load().map(\.name) == ["Phone"])
        #expect(asides(locations.devices).isEmpty)
    }

    // MARK: Attention

    @Test func attentionThatDoesNotReadIsSetAside() throws {
        let locations = try temporary()
        try garbage.write(to: locations.attention)
        let store = AttentionStore(locations: locations)
        #expect(store.load() == AttentionRecords())
        try expectSetAside(locations.attention, holding: garbage)

        let need = NeedID.permission(UUID())
        store.save(AttentionRecords(raised: [RaisedNote(need: need, at: Date(timeIntervalSince1970: 1_800_000_000))]))
        #expect(store.load().raised.map(\.need) == [need])
        #expect(temporaries(locations).isEmpty)
    }

    // MARK: Modes

    @Test func modesThatDoNotReadAreSetAside() throws {
        let locations = try temporary()
        try garbage.write(to: locations.modes)
        let store = ModeStore(locations: locations)
        #expect(store.remembered().isEmpty)
        try expectSetAside(locations.modes, holding: garbage)

        #expect(try store.remember(.string("plan"), for: "claude"))
        #expect(store.remembered()["claude"] == .string("plan"))
        #expect(temporaries(locations).isEmpty)
    }

    // MARK: Spend

    @Test func aLedgerThatDoesNotReadIsSetAsideAndSaysSo() throws {
        let locations = try temporary()
        try garbage.write(to: locations.spend)
        let ledger = SpendLedger(locations: locations)
        let day = Date()

        #expect(ledger.total(on: day).isEmpty)
        try expectSetAside(locations.spend, holding: garbage)
        #expect(ledger.note?.contains("spend.json could not be read") == true)

        try ledger.add(Cost(amount: 2, currency: "USD"), on: day)
        #expect(ledger.total(on: day) == ["USD": 2])
        #expect(asides(locations.spend).count == 1)
        #expect(temporaries(locations).isEmpty)
    }

    @Test func aLedgerAnEarlierBuildWroteStillLoads() throws {
        let locations = try temporary()
        let day = Date()
        let stamp = SpendLedger.stamp(for: day)
        try Data(#"{"days":{"\#(stamp)":{"USD":1.25}}}"#.utf8).write(to: locations.spend, options: .atomic)
        #expect(SpendLedger(locations: locations).total(on: day) == ["USD": Decimal(string: "1.25")!])
        #expect(asides(locations.spend).isEmpty)
    }

    // MARK: The daemon

    @Test func theDaemonCarriesOnAndTheLimitsPageSaysTheLedgerWasSetAside() async throws {
        let locations = try temporary()
        try locations.createDirectories()
        try garbage.write(to: locations.spend)
        try garbage.write(to: locations.devices)
        let core = DaemonCore(store: try AgentStore(locations: locations), locations: locations,
                              discovery: .findsEverything, launcher: FakeLauncher())
        await core.loadFromDisk()

        let state = await core.costState()
        #expect(state.today.isEmpty)
        #expect(state.note?.contains("spend.json") == true)
        try expectSetAside(locations.spend, holding: garbage)
        _ = await core.allAgents()
    }

    // MARK: Writing

    @Test func aWriteIsWholeAndLeavesNoTemporary() throws {
        let locations = try temporary()
        let url = locations.root.appendingPathComponent("nested/thing.json")
        try StoreCoding.writeAtomically(Data("one".utf8), to: url)
        try StoreCoding.writeAtomically(Data("two".utf8), to: url)
        #expect(try Data(contentsOf: url) == Data("two".utf8))
        #expect(((try? fileManager.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)) ?? []) == ["thing.json"])
    }

    @Test func twoSetAsidesInOneSecondKeepBoth() throws {
        let locations = try temporary()
        let url = locations.root.appendingPathComponent("x.json")
        try Data("a".utf8).write(to: url)
        let first = try #require(StoreCoding.setAside(url))
        try Data("b".utf8).write(to: url)
        let second = try #require(StoreCoding.setAside(url))
        #expect(first != second)
        #expect(try Data(contentsOf: first) == Data("a".utf8))
        #expect(try Data(contentsOf: second) == Data("b".utf8))
        #expect(StoreCoding.setAside(url) == nil, "nothing to set aside")
    }
}
