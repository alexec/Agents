import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// What the daemon reads and holds for a conversation stays bounded however many
/// conversations are read and however long each ran (#210).
@Suite("Bounded reads")
struct BoundedReadsTests {
    private func store() throws -> (AgentStore, StoreLocations) {
        let root = FileManager.default.temporaryDirectory.appending(path: "bounded-\(UUID().uuidString)")
        let locations = StoreLocations(root: root)
        return (try AgentStore(locations: locations), locations)
    }

    private func ask(_ text: String) -> TranscriptEntry { TranscriptEntry(kind: .userMessage(text)) }
    private func said(_ text: String) -> TranscriptEntry {
        TranscriptEntry(kind: .agentMessage(messageID: nil, text: text))
    }

    private func turns(_ count: Int, padding: Int = 0) -> [TranscriptEntry] {
        let pad = String(repeating: "x", count: padding)
        return (0..<count).flatMap { [ask("Q\($0)"), said("A\($0)" + pad)] }
    }

    // MARK: Transcript caches

    /// The seventeenth conversation read lets go of the one read longest ago, not all
    /// sixteen.
    @Test func theCachesLetGoOfTheOldestOneNotAll() async throws {
        let (store, _) = try store()
        let kept = UUID()
        let others = (0..<AgentStore.indexedTranscripts).map { _ in UUID() }  // index-ok: one per transcript held, never none
        for id in [kept] + others { try await store.appendAll(turns(2), for: id) }

        _ = try await store.turns(for: kept)
        for id in others.dropLast() { _ = try await store.turns(for: id) }
        // Read again, so it is not the oldest when the last one arrives.
        _ = try await store.transcript(for: kept)
        _ = try await store.turns(for: kept)
        _ = try await store.turns(for: others.last!)

        let held = await store.heldTranscripts()
        #expect(held.indexed.count == AgentStore.indexedTranscripts)
        #expect(held.turns.count == AgentStore.indexedTranscripts)
        #expect(held.indexed.contains(kept) && held.turns.contains(kept))
        #expect(!held.indexed.contains(others[0]) && !held.turns.contains(others[0]))
        #expect(held.indexed.contains(others.last!))
    }

    // MARK: read_session

    @Test func aShortSessionIsReadWhole() async throws {
        let (store, _) = try store()
        let id = UUID()
        try await store.appendAll(turns(3), for: id)
        let lines = try await store.historyLines(for: id, bytes: 1 << 20)
        #expect(lines.first == [0..<2])
        #expect(lines.latest == [[2..<4], [4..<6]])
        #expect(lines.leftOut == 0)
        #expect(lines.plan == nil)
    }

    /// A long session reads its first turn and the latest that fit the bytes, never
    /// the middle, and finds its last plan wherever it was set.
    @Test func aLongSessionIsReadFromTheEndWithinTheBytes() async throws {
        let (store, locations) = try store()
        let id = UUID()
        var entries = turns(2)
        entries.append(TranscriptEntry(kind: .planUpdated(Plan(entries: [PlanEntry(content: "Ship it")]))))
        entries += turns(2_000, padding: 200)
        try await store.appendAll(entries, for: id)
        let size = try FileManager.default.attributesOfItem(atPath: locations.transcript(id).path)[.size] as! Int

        let budget = 64 * 1024
        let lines = try await store.historyLines(for: id, bytes: budget)
        #expect(lines.first == [0..<2])
        #expect(lines.plan == 4)
        let total = 2 * 2 + 1 + 2 * 2_000
        #expect(lines.latest.last?.last?.upperBound == total)
        #expect(lines.latest.count > 10)
        #expect(lines.leftOut + lines.latest.count + 1 == 2_002)
        #expect(size > 4 * budget)

        // What the daemon makes of those lines: the first ask, the latest answers, the
        // plan, and the turns left out said.
        let core = DaemonCore(store: store, locations: locations)
        let header = SessionHistory.Header(id: id, title: "Long", runtime: "Claude", status: "Finished",
                                           folder: "/work", worktree: nil)
        let document = try #require(await core.history(of: id, header: header, bytes: budget))
        #expect(document.markdown.contains("**The person:** Q0"))
        #expect(document.markdown.contains("A1999"))
        #expect(!document.markdown.contains("A1000x"))
        #expect(document.markdown.contains("- [ ] Ship it"))
        #expect((document.leftOut ?? 0) >= lines.leftOut)
    }

    /// A turn longer than the bytes is its ask and as much of its end as fits.
    @Test func aTurnLongerThanTheBytesIsItsAskAndItsEnd() async throws {
        let (store, _) = try store()
        let id = UUID()
        var entries = turns(1)
        entries.append(ask("The long one"))
        entries += (0..<5_000).map { said("step \($0)") }
        try await store.appendAll(entries, for: id)
        let lines = try await store.historyLines(for: id, bytes: 16 * 1024)
        let latest = try #require(lines.latest.first)
        #expect(lines.latest.count == 1)
        #expect(latest.first == 2..<3)
        #expect(latest.last?.upperBound == 5_003)
        #expect((latest.last?.count ?? 0) < 5_000)
    }

    @Test func aSingleTurnTooLongKeepsItsAsk() async throws {
        let (store, _) = try store()
        let id = UUID()
        try await store.appendAll([ask("Only")] + (0..<5_000).map { said("step \($0)") }, for: id)
        let lines = try await store.historyLines(for: id, bytes: 8 * 1024)
        #expect(lines.first.first == 0..<1)
        #expect(lines.first.last?.upperBound == 5_001)
        #expect(lines.latest.isEmpty)
    }

    // MARK: list_sessions

    private let project = Project.standardize(URL(filePath: "/work/api"))

    private func sessions(_ count: Int, archivedEvery: Int = 0) -> [Agent] {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        return (0..<count).map { n in
            let archived = archivedEvery > 0 && n % archivedEvery == 0
            var agent = Agent(id: UUID(), runtimeID: "claude", cwd: project, title: "S\(n)",
                              state: archived ? .archived : .finished,
                              lastActivityAt: start.addingTimeInterval(-Double(n) * 60))
            if archived { agent.archivedReason = .byUser }
            return agent
        }
    }

    private func ids(_ text: String) -> [String] {
        text.split(separator: "\n").filter { $0.hasPrefix("- ") }.map { String($0.dropFirst(2).prefix(36)) }
    }

    @Test func theListIsAPageWithTheWayToTheNext() {
        let all = sessions(75, archivedEvery: 5)
        let first = SessionLookup.list(in: project, agents: all, caller: nil)
        #expect(ids(first).count == SessionLookup.pageSize)
        // Not archived first: the first page has none of the 15 archived.
        #expect(!first.contains("\u{201C}S0\u{201D}"))
        #expect(first.contains("45 more, 15 of them archived."))

        var seen = ids(first)
        var text = first
        while let range = text.range(of: "after: \""), seen.count < 100 {
            let after = String(text[range.upperBound...].prefix(36))
            text = SessionLookup.list(in: project, agents: all, caller: nil, limit: 40, after: after)
            seen += ids(text)
        }
        #expect(seen.count == 75)
        #expect(Set(seen).count == 75)
        #expect(!text.contains("more"))
        // The archived come last, and the oldest of them last of all.
        #expect(text.split(separator: "\n").last?.contains("\u{201C}S70\u{201D}") == true)
    }

    @Test func aPageIsNeverMoreThanTheLargest() {
        let all = sessions(150)
        #expect(ids(SessionLookup.list(in: project, agents: all, caller: nil, limit: 1_000)).count
                == SessionLookup.largestPage)
        #expect(ids(SessionLookup.list(in: project, agents: all, caller: nil, limit: 0)).count == 1)
        let gone = SessionLookup.list(in: project, agents: all, caller: nil, after: UUID().uuidString)
        #expect(gone.contains("Call list_sessions without `after`"))
    }

    @Test func theToolTakesALimitAndWhereToGoOnFrom() {
        let call = AppService.sessionCall(named: "mcp__agents__list_sessions", ["limit": 10, "after": " abc "])
        #expect(call.map { (try? $0.get()) == .list(limit: 10, after: "abc") } == true)
    }

    // MARK: Changes

    private func edit(_ n: Int, in folder: URL) -> [TranscriptEntry] {
        let diff = ToolCallContent.Diff(path: folder.path + "/f\(n).txt", oldText: nil, newText: "x\n")
        return [TranscriptEntry(kind: .toolCall(ToolCall(toolCallID: "c\(n)", title: "Edit", status: "completed",
                                                         content: [.diff(diff)])))]
    }

    /// The list names at most 500 files and counts the rest; the fold is caught up a
    /// page at a time and kept for the agents read latest.
    @Test func theChangesListIsCappedAndTheFoldsAreFew() async throws {
        let (store, locations) = try store()
        let folder = locations.root.appending(path: "work")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let core = DaemonCore(store: store, locations: locations)

        let busy = UUID()
        try await store.appendAll((0..<1_234).flatMap { edit($0, in: folder) }, for: busy)
        await core.addForTesting(Agent(id: busy, runtimeID: "claude", cwd: folder, state: .finished))
        let list = try await core.changesList(.init(agentID: busy))
        #expect(list.files.count == DaemonCore.listedChanges)
        #expect(list.more == 1_234 - DaemonCore.listedChanges)
        #expect(try await core.reported(for: busy).byFile.count == 1_234)

        for _ in 0..<8 {
            let id = UUID()
            try await store.appendAll(edit(0, in: folder), for: id)
            _ = try await core.reported(for: id)
        }
        let held = await core.heldFoldsForTesting()
        #expect(held.count == 8)
        #expect(!held.contains(busy))
    }
}

extension DaemonCore {
    func addForTesting(_ agent: Agent) {
        agents[agent.id] = agent
    }

    func heldFoldsForTesting() -> [UUID] { reportedChanges.keys }
}
