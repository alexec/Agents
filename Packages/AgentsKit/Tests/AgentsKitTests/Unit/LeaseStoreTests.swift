import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// `leases.json`: the book, kept across a restart (036 FR-008).
@Suite("Lease store")
struct LeaseStoreTests {
    private func temporary() -> StoreLocations {
        StoreLocations(root: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsLeaseStore-\(UUID().uuidString)", isDirectory: true))
    }

    /// Whole seconds, because the store keeps milliseconds and nothing finer.
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    @Test func aMissingFileIsAnEmptyBook() {
        #expect(LeaseStore(locations: temporary()).load().isEmpty)
    }

    @Test func theBookComesBackAsItWasWritten() throws {
        let store = LeaseStore(locations: temporary())
        var book = LeaseBook()
        let holder = UUID(), waiter = UUID()
        _ = book.request(.screen, kind: .screen, displayName: "Screen, mouse and keyboard",
                         by: holder, minutes: 20, wait: true, waitID: nil, now: t0)
        _ = book.request(.screen, kind: .screen, displayName: "Screen, mouse and keyboard",
                         by: waiter, minutes: nil, wait: true, waitID: UUID(), now: t0)
        try store.save(book)
        let back = store.load()
        #expect(back == book)
        #expect(back.entry(.screen)?.lease?.expiresAt == t0.addingTimeInterval(20 * 60))
    }

    @Test func anUnreadableFileIsSetAsideAndTheBookStartsEmpty() throws {
        let locations = temporary()
        try FileManager.default.createDirectory(at: locations.root, withIntermediateDirectories: true)
        try Data("not a book".utf8).write(to: locations.leases)
        #expect(LeaseStore(locations: locations).load().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: locations.leases.path))
        let aside = try FileManager.default.contentsOfDirectory(atPath: locations.root.path)
        #expect(aside.contains { $0.hasPrefix("leases.json.unreadable") })
    }
}
