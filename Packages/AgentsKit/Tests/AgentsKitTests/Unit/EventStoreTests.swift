import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// `events.jsonl` and `events-state.json`: what happened, kept across a restart (042 R13, R14).
@Suite("Event store")
struct EventStoreTests {
    private func temporary() -> StoreLocations {
        StoreLocations(root: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsEventStore-\(UUID().uuidString)", isDirectory: true))
    }

    /// Whole seconds, because the store keeps milliseconds and nothing finer.
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func event(_ position: EventPosition, _ name: String = "mac.wake") -> Event {
        Event(position: position, name: name, at: t0.addingTimeInterval(Double(position)), scope: .mac,
              sentence: "This Mac woke up.")
    }

    @Test func aMissingFileIsAnEmptyLog() {
        #expect(EventStore(locations: temporary()).load().events.isEmpty)
    }

    @Test func linesFoldBackIntoTheirEvents() {
        let locations = temporary()
        let store = EventStore(locations: locations)
        let agent = UUID()
        store.append(.event(event(1)))
        store.append(.event(event(2, "custom.ping")))
        store.append(.consequence(.woke(agentID: agent, title: "Waiter"), position: 2))
        store.append(.repeatOf(1, at: t0.addingTimeInterval(30), count: 3))

        let back = EventStore(locations: locations).load()
        #expect(back.events.map(\.position) == [1, 2])
        #expect(back.event(at: 1)?.count == 3)
        #expect(back.event(at: 1)?.lastAt == t0.addingTimeInterval(30))
        #expect(back.event(at: 2)?.consequences == [.woke(agentID: agent, title: "Waiter")])
    }

    @Test func aTornLastLineIsDropped() throws {
        let locations = temporary()
        let store = EventStore(locations: locations)
        store.append(.event(event(1)))
        let handle = try FileHandle(forWritingTo: locations.events)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"event":{"position":2,"na"#.utf8))
        try handle.close()
        #expect(EventStore(locations: locations).load().events.map(\.position) == [1])
    }

    @Test func aRewriteKeepsCountsAndConsequences() {
        let locations = temporary()
        let store = EventStore(locations: locations)
        var log = EventLog()
        let first = log.append(EventDraft(name: "mac.wake", at: t0, scope: .mac, sentence: "w"), position: 1, now: t0)
        #expect(first.event.position == 1)
        _ = log.append(EventDraft(name: "mac.wake", at: t0, scope: .mac, sentence: "w"), position: 2,
                       now: t0.addingTimeInterval(10))
        log.addConsequence(.fired(workflowID: "catch-up", folder: URL(fileURLWithPath: "/tmp/p"), agentID: nil), to: 1)
        store.rewrite(log)
        #expect(EventStore(locations: locations).load() == log)
    }

    @Test func anUnreadableFileIsSetAside() throws {
        let locations = temporary()
        try FileManager.default.createDirectory(at: locations.root, withIntermediateDirectories: true)
        try Data("not json\nnor this\n".utf8).write(to: locations.events)
        #expect(EventStore(locations: locations).load().events.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: locations.events.path))
    }

    @Test func theStateComesBackIncludingTheNextPosition() {
        let locations = temporary()
        var state = EventState()
        state.nextPosition = 42
        state.branchTips = ["/tmp/p": ["main": "abc"]]
        state.publishes = [UUID().uuidString: [t0]]
        EventStore(locations: locations).saveState(state)
        #expect(EventStore(locations: locations).loadState() == state)
    }
}
