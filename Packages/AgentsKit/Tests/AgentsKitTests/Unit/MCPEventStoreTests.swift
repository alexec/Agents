import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// Where each subscription to a server's events has got to (#383, data-model.md).
@Suite("MCP event records")
struct MCPEventStoreTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func scratch() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "mcp-events-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func aRecordRoundTrips() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MCPEventStore(root: root)
        #expect(store.load() == MCPEventRecords())
        let key = MCPEventRecords.key(project: URL(fileURLWithPath: "/tmp/p"), subscription: "0123456789abcdef")
        #expect(key == "/tmp/p|0123456789abcdef")
        var records = MCPEventRecords()
        records.subscriptions[key] = MCPSubscriptionRecord(
            cursor: "c2", previousCursor: "c1", seen: [.init(id: "a", at: now)], delivering: ["b"],
            lastPolledAt: now, missedSince: now,
            failure: MCPTriggerFailure(code: .unreachable, message: "Can't reach ci.", since: now),
            nextPollAt: now, lastNamedAt: now)
        try store.save(records)
        #expect(store.load() == records)
        #expect(store.url.lastPathComponent == "mcp-events.json")
    }

    @Test func seenKeepsAWeekAndAtMostTwoThousand() {
        var record = MCPSubscriptionRecord(lastNamedAt: now)
        record.see(["old"], at: now.addingTimeInterval(-8 * 24 * 60 * 60))
        record.see((0..<2100).map { "id\($0)" }, at: now)
        #expect(!record.hasSeen("old"))
        #expect(record.seen.count == MCPSubscriptionRecord.seenLimit)
        #expect(!record.hasSeen("id0"))
        #expect(record.hasSeen("id2099"))
        record.see(["id2099"], at: now)
        #expect(record.seen.count == MCPSubscriptionRecord.seenLimit)
    }

    @Test func aRecordNoWorkflowNamesForADayIsDropped() {
        var records = MCPEventRecords(subscriptions: [
            "p|named": MCPSubscriptionRecord(lastNamedAt: now.addingTimeInterval(-3 * 24 * 60 * 60)),
            "p|recent": MCPSubscriptionRecord(lastNamedAt: now.addingTimeInterval(-60 * 60)),
            "p|stale": MCPSubscriptionRecord(lastNamedAt: now.addingTimeInterval(-25 * 60 * 60)),
        ])
        let dropped = records.prune(keeping: ["p|named"], now: now)
        #expect(dropped)
        #expect(Set(records.subscriptions.keys) == ["p|named", "p|recent"])
        #expect(records.subscriptions["p|named"]?.lastNamedAt == now)
        let again = records.prune(keeping: ["p|named"], now: now)
        #expect(!again)
    }

    @Test func aFileThatDoesNotDecodeReadsAsEmpty() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MCPEventStore(root: root)
        try Data("not json".utf8).write(to: store.url)
        #expect(store.load() == MCPEventRecords())
    }
}
