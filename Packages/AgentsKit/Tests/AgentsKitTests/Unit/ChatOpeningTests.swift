import Foundation
import Testing
@testable import AgentsKitCore

/// How a chat's history opens, and what happens when it does not (#400).
@MainActor
@Suite("Opening a chat's history")
struct ChatOpeningTests {
    private func page(_ texts: [String], firstIndex: Int = 0) -> TranscriptPage {
        TranscriptPage(firstIndex: firstIndex, total: firstIndex + texts.count,
                       entries: texts.map { TranscriptEntry(kind: .agentMessage(messageID: nil, text: $0)) })
    }

    private func entry(_ model: AgentsModel, _ agentID: UUID, _ text: String) throws {
        model.apply(DaemonAPI.Notification.agentEntry, try JSONValue.encoding(DaemonAPI.EntryNotification(
            agentID: agentID, entry: TranscriptEntry(kind: .agentMessage(messageID: nil, text: text)))))
    }

    /// Two loads of one chat, as opening it and a reconnect make, answered in reverse:
    /// the older answer is not shown over the newer, and what was heard since stays.
    @Test func anOlderAnswerLandingLastIsDropped() throws {
        let model = AgentsModel()
        let id = UUID()
        model.watching = id
        let first = model.beginTranscriptLoad()
        let second = model.beginTranscriptLoad()

        let newer = ChatOpening.Loaded(turns: TurnsPage(turns: [], firstTurn: 0, openStart: 0),
                                       page: page(["one", "two"]), turnsFailure: nil)
        #expect(model.takeOpening(newer, load: second))
        try entry(model, id, "heard after")
        let older = ChatOpening.Loaded(turns: TurnsPage(turns: [], firstTurn: 0, openStart: 0),
                                       page: page(["one"]), turnsFailure: nil)
        #expect(!model.takeOpening(older, load: first))
        #expect(model.entries.compactMap(\.text) == ["one", "two", "heard after"])

        // Nor does the older one's failure say anything over the page on screen.
        model.failOpening("closed", load: first)
        #expect(model.transcriptLoadFailure == nil)
    }

    @Test func aFailedOpeningIsSaidAndALaterPageClearsIt() {
        let model = AgentsModel()
        model.watching = UUID()
        let load = model.beginTranscriptLoad()
        model.failOpening("No answer to agents/transcript in time.", load: load)
        #expect(model.transcriptLoadFailure?.nothingLoaded == true)
        #expect(model.transcriptLoadFailure?.sentence.contains("did not load") == true)

        let retry = model.beginTranscriptLoad()
        model.takeOpening(ChatOpening.Loaded(turns: TurnsPage(turns: [], firstTurn: 0, openStart: 0),
                                             page: page(["back"]), turnsFailure: nil), load: retry)
        #expect(model.transcriptLoadFailure == nil)
        #expect(model.entries.count == 1)
    }

    @Test func leavingTheChatForgetsItsFailure() {
        let model = AgentsModel()
        model.watching = UUID()
        model.failOpening("closed", load: model.beginTranscriptLoad())
        model.watching = UUID()
        #expect(model.transcriptLoadFailure == nil)
    }

    /// The turns failing used to be an empty list, silently: the chat showed its last
    /// page and nothing before it. It still opens on that page, and says why.
    @Test func turnsThatFailStillOpenTheLastPageAndSaySo() async throws {
        struct Broken: Error {}
        var askedFrom: Int?
        let loaded = try await ChatOpening.load(
            turns: { throw Broken() },
            transcript: { from in askedFrom = from; return self.page(["last"], firstIndex: 300) },
            describe: { _ in "the turns are unreadable" })
        #expect(askedFrom == 0)
        #expect(loaded.turnsFailure == "the turns are unreadable")

        let model = AgentsModel()
        model.watching = UUID()
        model.takeOpening(loaded, load: model.beginTranscriptLoad())
        #expect(model.entries.count == 1)
        #expect(model.transcriptLoadFailure == TranscriptLoadFailure(nothingLoaded: false,
                                                                     reason: "the turns are unreadable"))
    }

    /// A host too old to keep turns is not a failure: it gives the lot.
    @Test func aHostWithoutTurnsIsNotAFailure() async throws {
        let loaded = try await ChatOpening.load(
            turns: { throw JSONRPCError.methodNotFound(DaemonAPI.Method.agentsTurns) },
            transcript: { _ in self.page(["all"]) })
        #expect(loaded.turnsFailure == nil)
    }

    @Test func theTurnsSayWhereTheTranscriptStarts() async throws {
        var askedFrom: Int?
        let loaded = try await ChatOpening.load(
            turns: { TurnsPage(turns: [], firstTurn: 3, openStart: 42) },
            transcript: { from in askedFrom = from; return self.page(["open"], firstIndex: 42) })
        #expect(askedFrom == 42)
        #expect(loaded.turns.firstTurn == 3)
    }

    @Test func aTranscriptThatDoesNotComeThrows() async {
        struct Lost: Error {}
        await #expect(throws: Lost.self) {
            _ = try await ChatOpening.load(turns: { TurnsPage(turns: [], firstTurn: 0, openStart: 0) },
                                           transcript: { _ in throw Lost() })
        }
    }
}
