import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// `pool.json`, `allowances.json` and `switches.jsonl` (052, R6).
@Suite("Where the pool is kept")
struct PoolStoreTests {
    private func store() -> (PoolStore, StoreLocations) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("PoolStore-\(UUID().uuidString)", isDirectory: true)
        let locations = StoreLocations(root: root)
        return (PoolStore(locations: locations), locations)
    }

    @Test func nothingWrittenIsAnEmptyPool() {
        let (store, _) = store()
        #expect(store.load() == PoolSettings())
        #expect(store.loadAllowances().isEmpty)
        #expect(store.switches(since: .distantPast).isEmpty)
    }

    @Test func itRoundTrips() throws {
        let (store, _) = store()
        let pool = PoolSettings(isOn: true, entries: [PoolEntry(runtimeID: "claude", payment: .allowance(label: "Max plan")),
                                                      PoolEntry(runtimeID: "codex", payment: .allowance(label: nil))])
        try store.save(pool)
        #expect(store.load() == pool)
        // Whole seconds: the store writes dates as the other daemon files do.
        let at = Date(timeIntervalSince1970: 1_790_000_000)
        var state = AllowanceState(credentialKey: "claude:sign-in", entryID: pool.entries[0].id, since: at)
        state.markOut(.allowanceSpent, until: at.addingTimeInterval(60), payment: .allowance(label: nil), now: at, from: .typedFailure)
        try store.saveAllowances([state])
        #expect(store.loadAllowances() == [state])
    }

    @Test func switchesOlderThanThirtyDaysAreDropped() throws {
        let (store, locations) = store()
        let now = Date()
        func record(daysAgo: Double) -> SwitchRecord {
            SwitchRecord(at: now.addingTimeInterval(-daysAgo * 86400), agentID: UUID(),
                         from: .init(runtimeID: "claude"), to: .init(runtimeID: "codex"),
                         reason: .allowanceSpent, billing: .allowance(label: nil))
        }
        try store.append(record(daysAgo: 40))
        try store.append(record(daysAgo: 2))
        try store.append(record(daysAgo: 0.1))
        let kept = store.switches(since: now.addingTimeInterval(-30 * 86400), trim: true)
        #expect(kept.count == 2)
        let lines = try String(contentsOf: locations.switches, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 2, "the old one is gone from the file too")
    }

    @Test func anUnreadableFileIsSetAsideNotFatal() throws {
        let (store, locations) = store()
        try FileManager.default.createDirectory(at: locations.root, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: locations.pool)
        #expect(store.load() == PoolSettings())
    }
}
