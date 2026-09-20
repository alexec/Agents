import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

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

        let read = try await store.load(agent.id).agent
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

    // MARK: Rules of the record, not of this test file (020, US3)

    /// The four forbidden shapes, each as a record somebody could construct.
    private func forbidden() -> [(name: String, agent: Agent, rule: String)] {
        var stoppedWithNoReason = anAgent()
        stoppedWithNoReason.state = .stopped

        var finishedWrongly = anAgent()
        finishedWrongly.state = .finished
        finishedWrongly.endedReason = .refusal

        var archivedWithNoReason = anAgent()
        archivedWithNoReason.state = .archived
        archivedWithNoReason.endedReason = .endTurn

        var startingWithAnEnding = anAgent()
        startingWithAnEnding.state = .starting
        startingWithAnEnding.endedReason = .endTurn

        return [
            ("stopped with no reason", stoppedWithNoReason, "2"),
            ("finished that did not end in endTurn", finishedWrongly, "3"),
            ("archived with nobody having archived it", archivedWithNoReason, "1"),
            ("starting while carrying an ending", startingWithAnEnding, "4"),
        ]
    }

    /// SC-006. Until 020 these were asserted against `isConsistent` and enforced
    /// nowhere, so a record breaking one could be written, saved, read back and
    /// carried forever — and the first anybody knew was a group that looked wrong.
    @Test func everyForbiddenRecordIsRefused() async throws {
        for (name, agent, rule) in forbidden() {
            let (store, locations) = try temporaryStore()
            await #expect(throws: AgentStore.RecordRefused.self, "rule \(rule): \(name)") {
                try await store.save(agent)
            }
            // And nothing partial reached disk, which is the half of SC-006 a throw
            // alone does not prove.
            #expect(!FileManager.default.fileExists(atPath: locations.record(agent.id).path),
                    "rule \(rule): a refused record was written anyway")
        }
    }

    /// The contrast, so the test above cannot pass by everything being refused.
    @Test func aRecordThatObeysTheRulesIsSaved() async throws {
        let (store, locations) = try temporaryStore()
        var agent = anAgent()
        agent.state = .stopped
        agent.endedReason = .cancelled
        try await store.save(agent)
        #expect(FileManager.default.fileExists(atPath: locations.record(agent.id).path))
    }

    /// SC-007. A record already on disk is mended rather than refused, because
    /// refusing a read loses the agent and a person who cannot see an agent can do
    /// nothing about it.
    @Test func everyBrokenRecordOnDiskOpensAndSaysSo() async throws {
        let expected: [(state: String, extra: String, mend: AgentStore.Mend, becomes: AgentState, reason: EndedReason?)] = [
            ("stopped", "", .stoppedWithNoReason, .stopped, .unrecognised),
            ("finished", #""endedReason": "refusal","#, .finishedWithoutEndTurn(.refusal), .stopped, .refusal),
            ("archived", #""endedReason": "endTurn","#, .archivedWithNoReason, .archived, .endTurn),
            ("starting", #""endedReason": "endTurn","#, .startingWithAnEnding, .stopped, .daemonGone),
        ]
        for case_ in expected {
            let (store, locations) = try temporaryStore()
            let id = UUID()
            try FileManager.default.createDirectory(at: locations.agent(id), withIntermediateDirectories: true)
            let json = """
                {"id": "\(id.uuidString)", "runtimeID": "copilot", "cwd": "file:///tmp",
                 "state": "\(case_.state)", \(case_.extra)
                 "createdAt": "2026-09-20T09:00:00.000Z", "lastActivityAt": "2026-09-20T09:00:00.000Z"}
                """
            try Data(json.utf8).write(to: locations.record(id))

            let read = try await store.load(id)
            #expect(read.mend == case_.mend, "\(case_.state)")
            #expect(read.agent.state == case_.becomes, "\(case_.state)")
            #expect(read.agent.endedReason == case_.reason, "\(case_.state)")
            // Whatever it was, it is now a record the rules allow — which is the
            // point, and is what makes it safe to hand to the rest of the app.
            #expect(read.agent.isConsistent, "\(case_.state) was mended into another forbidden shape")
            // And the mend is announced, not silent.
            #expect(!case_.mend.summary.isEmpty)
        }
    }

    /// A mended record comes back through `loadAll` too, with its mend, which is how
    /// `loadFromDisk` knows to write the transcript line.
    @Test func loadAllCarriesTheMendsAlongsideTheAgents() async throws {
        let (store, locations) = try temporaryStore()
        let id = UUID()
        try FileManager.default.createDirectory(at: locations.agent(id), withIntermediateDirectories: true)
        try Data("""
            {"id": "\(id.uuidString)", "runtimeID": "copilot", "cwd": "file:///tmp",
             "state": "stopped", "createdAt": "2026-09-20T09:00:00.000Z", "lastActivityAt": "2026-09-20T09:00:00.000Z"}
            """.utf8).write(to: locations.record(id))

        let all = await store.loadAll()
        #expect(all.agents.count == 1)
        #expect(all.unreadable.isEmpty, "a forbidden record is a different thing from an unreadable one")
        #expect(all.mends[id] == .stoppedWithNoReason)
    }

    @Test func aTitleFallsBackToTheFirstLineOfTheInstruction() {
        #expect(Agent.fallbackTitle(from: "Fix the bug\nand then some") == "Fix the bug")
        #expect(Agent.fallbackTitle(from: String(repeating: "x", count: 200)).count == 80)
    }

    /// A ceiling is something the reader set, so the one thing this must never do is
    /// lose one — neither by sweeping it into `unknownFields` on the way in, nor by
    /// dropping somebody else's field on the way out.
    @Test func aCeilingSetByTheReaderSurvivesEveryRoundTrip() throws {
        // A record written before 010: no `costCeiling` key at all.
        let older = """
        {"id":"\(UUID().uuidString)","runtimeID":"claude","cwd":"file:///tmp/",
         "state":"finished","endedReason":"endTurn",
         "createdAt":"2026-09-19T09:00:00.000Z","lastActivityAt":"2026-09-19T09:00:00.000Z"}
        """
        let read = try StoreCoding.decoder.decode(Agent.self, from: Data(older.utf8))
        #expect(read.costCeiling == nil, "no ceiling of its own: the app-wide limit applies")
        #expect(read.unknownFields["costCeiling"] == nil, "a key we know is never unknown")

        // Written by this build, read back by it.
        var withCeiling = read
        withCeiling.costCeiling = Cost(amount: 2.5, currency: "USD")
        let encoded = try StoreCoding.encoder.encode(withCeiling)
        let back = try StoreCoding.decoder.decode(Agent.self, from: encoded)
        #expect(back.costCeiling == Cost(amount: 2.5, currency: "USD"))
        #expect(back.unknownFields.isEmpty)

        // A ceiling of zero is a ceiling, and must not encode away as absent.
        withCeiling.costCeiling = Cost(amount: 0, currency: "USD")
        let zeroed = try StoreCoding.decoder.decode(
            Agent.self, from: try StoreCoding.encoder.encode(withCeiling))
        #expect(zeroed.costCeiling?.amount == 0, "nothing may run is not the same as no limit")

        // A key a newer build wrote survives a read and a write by this one.
        let newer = """
        {"id":"\(UUID().uuidString)","runtimeID":"claude","cwd":"file:///tmp/",
         "state":"finished","endedReason":"endTurn","costCeiling":{"amount":1,"currency":"GBP"},
         "createdAt":"2026-09-19T09:00:00.000Z","lastActivityAt":"2026-09-19T09:00:00.000Z",
         "somethingFromTheFuture":{"kept":true}}
        """
        let fromTheFuture = try StoreCoding.decoder.decode(Agent.self, from: Data(newer.utf8))
        #expect(fromTheFuture.costCeiling == Cost(amount: 1, currency: "GBP"))
        #expect(fromTheFuture.unknownFields["somethingFromTheFuture"] != nil)
        let rewritten = try StoreCoding.decoder.decode(
            Agent.self, from: try StoreCoding.encoder.encode(fromTheFuture))
        #expect(rewritten.unknownFields["somethingFromTheFuture"] != nil,
                "an older build must not quietly delete what a newer one wrote")
        #expect(rewritten.costCeiling == Cost(amount: 1, currency: "GBP"))
    }
}

@Suite("Reading a transcript")
struct TranscriptReadingTests {
    private func message(_ text: String, _ id: String?) -> TranscriptEntry {
        TranscriptEntry(kind: .agentMessage(messageID: id, text: text))
    }

    @Test func chunksOfOneMessageAreJoinedBack() {
        let joined = TranscriptEntry.coalesced([
            message("Hello", "m1"), message(" there", "m1"), message(".", "m1"),
        ])
        #expect(joined.count == 1)
        #expect(joined.first?.text == "Hello there.")
    }

    @Test func twoMessagesStayTwoMessages() {
        let joined = TranscriptEntry.coalesced([
            message("First", "m1"), message(" bit", "m1"),
            message("Second", "m2"),
        ])
        #expect(joined.map(\.text) == ["First bit", "Second"])
    }

    @Test func chunksWithNoIdStillReadAsOneMessage() {
        // Copilot sends no messageId at all, so the run of chunks is the message.
        let joined = TranscriptEntry.coalesced([
            message("Created ", nil), message("hello", nil), message(".txt", nil),
        ])
        #expect(joined.map(\.text) == ["Created hello.txt"])
    }

    @Test func anythingBetweenThemBreaksTheRun() {
        let entries = [
            message("Before", nil),
            TranscriptEntry(kind: .toolCall(ToolCall(title: "Write a file"))),
            message("After", nil),
        ]
        #expect(TranscriptEntry.coalesced(entries).count == 3)
    }

    @Test func thoughtsAndMessagesDoNotRunTogether() {
        let entries = [
            message("Said", "m1"),
            TranscriptEntry(kind: .agentThought(messageID: "m1", text: "Thought")),
        ]
        #expect(TranscriptEntry.coalesced(entries).count == 2)
    }
}
