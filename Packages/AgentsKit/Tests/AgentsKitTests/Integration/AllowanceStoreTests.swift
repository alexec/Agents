import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// `allowances.json` (052, R6; 065). The pool's own files are no longer read.
@Suite("Where each runtime's allowance is kept")
struct AllowanceStoreTests {
    private func store() -> (AllowanceStore, StoreLocations) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AllowanceStore-\(UUID().uuidString)", isDirectory: true)
        let locations = StoreLocations(root: root)
        return (AllowanceStore(locations: locations), locations)
    }

    @Test func nothingWrittenIsNoState() {
        let (store, _) = store()
        #expect(store.loadAllowances().isEmpty)
    }

    @Test func itRoundTrips() throws {
        let (store, _) = store()
        // Whole seconds: the store writes dates as the other daemon files do.
        let at = Date(timeIntervalSince1970: 1_790_000_000)
        var state = AllowanceState(credentialKey: "claude:sign-in", entryID: UUID(), since: at)
        state.markOut(.allowanceSpent, until: at.addingTimeInterval(60), payment: .allowance(label: nil), now: at, from: .typedFailure)
        try store.saveAllowances([state])
        #expect(store.loadAllowances() == [state])
    }

    @Test func anUnreadableFileIsSetAsideNotFatal() throws {
        let (store, locations) = store()
        try FileManager.default.createDirectory(at: locations.root, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: locations.allowances)
        #expect(store.loadAllowances().isEmpty)
    }
}
