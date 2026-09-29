import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

@Suite("Turns kept beside the transcript")
struct TurnStoreTests {
    private func store() throws -> (AgentStore, StoreLocations) {
        let root = FileManager.default.temporaryDirectory.appending(path: "turns-\(UUID().uuidString)")
        let locations = StoreLocations(root: root)
        return (try AgentStore(locations: locations), locations)
    }

    private func ask(_ text: String) -> TranscriptEntry { TranscriptEntry(kind: .userMessage(text)) }
    private func said(_ text: String) -> TranscriptEntry {
        TranscriptEntry(kind: .agentMessage(messageID: nil, text: text))
    }

    @Test func finishedTurnsAreWrittenAndTheOpenOneIsNot() async throws {
        let (store, locations) = try store()
        let id = UUID()
        try await store.appendAll([ask("One"), said("a"), ask("Two"), said("b")], for: id)
        let page = try await store.turns(for: id)
        #expect(page.turns.map { $0.ask?.text } == ["One"])
        #expect(page.openStart == 2)
        let lines = try String(contentsOf: locations.turns(id), encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 1)

        try await store.appendAll([ask("Three"), said("c")], for: id)
        let later = try await store.turns(for: id)
        #expect(later.turns.map { $0.last?.text } == ["a", "b"])
        #expect(later.openStart == 4)
    }

    @Test func aStoreWithNoTurnsFileBuildsItFromTheTranscript() async throws {
        let (store, locations) = try store()
        let id = UUID()
        var entries: [TranscriptEntry] = []
        for n in 0..<3_000 { entries += [ask("Q\(n)"), said("A\(n)")] }
        try await store.appendAll(entries, for: id)
        let fresh = try AgentStore(locations: locations)
        let page = try await fresh.turns(for: id, limit: 10)
        #expect(page.firstTurn == 2_989)
        #expect(page.turns.count == 10)
        #expect(page.turns.last?.last?.text == "A2998")
        #expect(page.openStart == 5_998)
    }

    @Test func theTranscriptCanStartFromTheOpenTurn() async throws {
        let (store, locations) = try store()
        let id = UUID()
        try await store.appendAll([ask("One"), said("a"), ask("Two"), said("b"), said("c")], for: id)
        let core = DaemonCore(store: store, locations: locations)
        let page = try await core.transcript(DaemonAPI.TranscriptRequest(agentID: id, from: 2))
        #expect(page.firstIndex == 2)
        #expect(page.entries.count == 3)
    }
}
