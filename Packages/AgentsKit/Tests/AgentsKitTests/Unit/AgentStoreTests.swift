import Foundation
import Testing
@testable import AgentsKit

@Suite("Agent store")
struct AgentStoreTests {
    private func temporaryStore() throws -> (AgentStore, StoreLocations) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsKitTests-\(UUID().uuidString)", isDirectory: true)
        let locations = StoreLocations(root: root)
        return (try AgentStore(locations: locations), locations)
    }

    private func anAgent() -> Agent {
        Agent(runtimeID: "copilot", cwd: URL(fileURLWithPath: "/tmp"), state: .running)
    }

    @Test func savesAndReadsARecord() async throws {
        let (store, _) = try temporaryStore()
        var agent = anAgent()
        agent.title = "Pineapple"
        try await store.save(agent)

        let read = try await store.load(agent.id)
        #expect(read.id == agent.id)
        #expect(read.title == agent.title)
        #expect(read.runtimeID == agent.runtimeID)
        #expect(read.cwd == agent.cwd)
        #expect(read.state == agent.state)
        // Timestamps survive to the millisecond, which is the precision the format has.
        #expect(abs(read.createdAt.timeIntervalSince(agent.createdAt)) < 0.001)

        let all = await store.loadAll()
        #expect(all.agents.count == 1)
        #expect(all.unreadable.isEmpty)
    }

    @Test func appendsATranscriptAndReadsItBackInOrder() async throws {
        let (store, _) = try temporaryStore()
        let agent = anAgent()
        try await store.save(agent)

        for i in 0..<50 {
            try await store.append(TranscriptEntry(kind: .agentMessage(messageID: "m", text: "line \(i)")),
                                   for: agent.id)
        }
        await store.closeTranscript(for: agent.id)

        let page = try await store.transcript(for: agent.id, limit: 200)
        #expect(page.total == 50)
        #expect(page.entries.count == 50)
        #expect(page.entries.first?.text == "line 0")
        #expect(page.entries.last?.text == "line 49")
        #expect(!page.hasMoreBefore)
    }

    @Test func readsAPageRatherThanTheWholeThing() async throws {
        let (store, _) = try temporaryStore()
        let agent = anAgent()
        try await store.save(agent)
        for i in 0..<500 {
            try await store.append(TranscriptEntry(kind: .agentMessage(messageID: nil, text: "\(i)")), for: agent.id)
        }
        await store.closeTranscript(for: agent.id)

        let last = try await store.transcript(for: agent.id, limit: 20)
        #expect(last.entries.count == 20)
        #expect(last.firstIndex == 480)
        #expect(last.entries.first?.text == "480")
        #expect(last.hasMoreBefore)

        let earlier = try await store.transcript(for: agent.id, before: last.firstIndex, limit: 20)
        #expect(earlier.entries.count == 20)
        #expect(earlier.entries.last?.text == "479")
    }

    @Test func aHalfWrittenLastLineIsNotAnEntry() async throws {
        // A daemon killed mid-write leaves a fragment. The record is worth more with
        // the fragment dropped than it is unreadable.
        let (store, locations) = try temporaryStore()
        let agent = anAgent()
        try await store.save(agent)
        try await store.append(TranscriptEntry(kind: .runtimeNote("whole")), for: agent.id)
        await store.closeTranscript(for: agent.id)

        let handle = try FileHandle(forWritingTo: locations.transcript(agent.id))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"id":"half-writ"#.utf8))
        try handle.close()

        let page = try await store.transcript(for: agent.id)
        #expect(page.total == 1)
        #expect(page.entries.count == 1)
        #expect(page.entries.first?.text == "whole")
    }

    @Test func anUnreadableRecordDoesNotHideTheOthers() async throws {
        let (store, locations) = try temporaryStore()
        let good = anAgent()
        try await store.save(good)

        let badID = UUID()
        try FileManager.default.createDirectory(at: locations.agent(badID), withIntermediateDirectories: true)
        try Data("not an agent".utf8).write(to: locations.record(badID))

        let all = await store.loadAll()
        #expect(all.agents.map(\.id) == [good.id])
        #expect(all.unreadable.count == 1)
    }

    @Test func theRecordKeepsItsInvariants() {
        var agent = anAgent()
        agent.state = .stopped
        #expect(!agent.isConsistent, "stopped without a reason is not a state we may write")
        agent.endedReason = .cancelled
        #expect(agent.isConsistent)

        agent.state = .finished
        agent.endedReason = .refusal
        #expect(!agent.isConsistent, "finished can only mean endTurn")
        agent.endedReason = .endTurn
        #expect(agent.isConsistent)

        agent.state = .archived
        #expect(!agent.isConsistent, "archived without a reason is not a state we may write")
        agent.archivedReason = .byUser
        #expect(agent.isConsistent)
    }

    @Test func aTitleFallsBackToTheFirstLineOfTheInstruction() {
        #expect(Agent.fallbackTitle(from: "Fix the bug\nand then some") == "Fix the bug")
        #expect(Agent.fallbackTitle(from: String(repeating: "x", count: 200)).count == 80)
    }
}
