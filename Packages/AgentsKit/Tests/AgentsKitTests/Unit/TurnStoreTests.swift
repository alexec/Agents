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

    private func keptTurns(_ locations: StoreLocations, _ id: UUID) throws -> [TurnSummary] {
        guard let text = try? String(contentsOf: locations.turns(id), encoding: .utf8) else { return [] }
        return try text.split(separator: "\n").map {
            try StoreCoding.decoder.decode(TurnSummary.self, from: Data($0.utf8))
        }
    }

    /// The first open of a long conversation makes only the turns it shows, and the rest
    /// as the reader goes back, keeping them once there is no gap before them (#91).
    @Test func theLastTurnsComeFirstAndTheRestAsTheReaderGoesBack() async throws {
        let (store, locations) = try store()
        let id = UUID()
        var entries: [TranscriptEntry] = []
        for n in 0..<30 { entries += [ask("Q\(n)"), said("A\(n)"), said("more")] }
        try await store.appendAll(entries, for: id)
        let fresh = try AgentStore(locations: locations)
        let last = try await fresh.turns(for: id, limit: 5)
        #expect(last.firstTurn == 24)
        #expect(last.turns.map { $0.ask?.text } == ["Q24", "Q25", "Q26", "Q27", "Q28"])
        #expect(last.turns.map(\.start) == [72, 75, 78, 81, 84])
        #expect(last.turns.map(\.end) == [75, 78, 81, 84, 87])
        #expect(last.openStart == 87)
        // Nothing before them is made yet, so nothing is kept.
        #expect(try keptTurns(locations, id).isEmpty)

        let first = try await fresh.turns(for: id, before: 24, limit: 24)
        #expect(first.firstTurn == 0)
        #expect(first.turns.map { $0.ask?.text } == (0..<24).map { "Q\($0)" })
        // The gap is filled, so all 29 are kept, in order.
        #expect(try keptTurns(locations, id).map(\.start) == (0..<29).map { $0 * 3 })

        // A host started again reads them rather than makes them, and gets the same.
        let again = try await AgentStore(locations: locations).turns(for: id, limit: 5)
        #expect(again == last)
    }

    /// A turns file that no longer matches its transcript (written by an older build that
    /// counted differently, or for another transcript) is made again from the first turn
    /// that does not match, and so is one that is missing.
    @Test func aStaleOrMissingTurnsFileIsMadeAgain() async throws {
        let (store, locations) = try store()
        let id = UUID()
        var entries: [TranscriptEntry] = []
        for n in 0..<6 { entries += [ask("Q\(n)"), said("A\(n)")] }
        try await store.appendAll(entries, for: id)
        _ = try await store.turns(for: id)
        var kept = try keptTurns(locations, id)
        try #require(kept.count == 5)

        // Turns 3 and 4 off by one, as a build that skipped an unreadable line had them.
        kept[3].start += 1
        kept[4].end += 1
        var data = Data()
        for turn in kept { data += try StoreCoding.encoder.encode(turn) + Data([0x0A]) }
        try data.write(to: locations.turns(id))
        let page = try await AgentStore(locations: locations).turns(for: id)
        #expect(page.turns.map(\.start) == [0, 2, 4, 6, 8])
        #expect(page.turns.map { $0.ask?.text } == ["Q0", "Q1", "Q2", "Q3", "Q4"])
        #expect(try keptTurns(locations, id).map(\.start) == [0, 2, 4, 6, 8])

        try FileManager.default.removeItem(at: locations.turns(id))
        let rebuilt = try await AgentStore(locations: locations).turns(for: id)
        #expect(rebuilt == page)
        #expect(try keptTurns(locations, id).count == 5)
    }

    /// Only the person's asks start a turn: not the app's own prompt, and not the word
    /// turning up in what an agent said or a tool printed.
    @Test func onlyThePersonsAskStartsATurn() async throws {
        let (store, locations) = try store()
        let id = UUID()
        try await store.appendAll([
            ask("One"), said(#"{"userMessage":"not an ask"}"#),
            TranscriptEntry(kind: .userMessage("How did it go?", from: .app)), said("fine"),
            ask("Two"), said("b"),
        ], for: id)
        let page = try await AgentStore(locations: locations).turns(for: id)
        #expect(page.turns.map { $0.ask?.text } == ["One"])
        #expect(page.turns.first?.end == 4)
        #expect(page.openStart == 4)
    }

    /// A line that will not decode is still a line: the turns after it start and end
    /// where `agents/transcript` counts them.
    @Test func anUnreadableLineKeepsTheCount() async throws {
        let (store, locations) = try store()
        let id = UUID()
        try await store.appendAll([ask("One"), said("a")], for: id)
        await store.closeAll()
        let handle = try FileHandle(forWritingTo: locations.transcript(id))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{not json\n".utf8))
        try handle.close()
        try await store.appendAll([said("b"), ask("Two"), said("c")], for: id)
        let page = try await store.turns(for: id)
        #expect(page.turns.first?.end == 4)
        #expect(page.turns.first?.steps != nil)
        #expect(page.openStart == 4)
    }

    /// After a page from the end, the turns before it are made in the background, and
    /// kept, so the next start has them all (#91).
    @Test func theTurnsBeforeThePageAreFilledIn() async throws {
        let (store, locations) = try store()
        let id = UUID()
        var entries: [TranscriptEntry] = []
        for n in 0..<40 { entries += [ask("Q\(n)"), said("A\(n)")] }
        try await store.appendAll(entries, for: id)
        let fresh = try AgentStore(locations: locations)
        let last = try await fresh.turns(for: id, limit: 3)
        #expect(try keptTurns(locations, id).isEmpty)
        await fresh.fillTurns(for: id)
        let kept = try keptTurns(locations, id)
        #expect(kept.map(\.start) == (0..<39).map { $0 * 2 })
        #expect(kept.map { $0.ask?.text } == (0..<39).map { "Q\($0)" })
        #expect(try await AgentStore(locations: locations).turns(for: id, limit: 3) == last)
        // Nothing left to fill, and nothing written twice.
        await fresh.fillTurns(for: id)
        #expect(try keptTurns(locations, id).count == 39)
    }
}
