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
            transcript: { from, _ in askedFrom = from; return self.page(["last"], firstIndex: 300) },
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
            transcript: { _, _ in self.page(["all"]) })
        #expect(loaded.turnsFailure == nil)
    }

    @Test func theTurnsSayWhereTheTranscriptStarts() async throws {
        var askedFrom: Int?
        let loaded = try await ChatOpening.load(
            turns: { TurnsPage(turns: [], firstTurn: 3, openStart: 42) },
            transcript: { from, _ in askedFrom = from; return self.page(["open"], firstIndex: 42) })
        #expect(askedFrom == 42)
        #expect(loaded.turns.firstTurn == 3)
    }

    /// The page from a turn's start, as a host answers `from` and `limit`: the last
    /// `limit` entries, none before `from`.
    private func tail(of turn: Range<Int>, from: Int, limit: Int) -> TranscriptPage {
        let first = max(from, turn.upperBound - limit)
        return TranscriptPage(firstIndex: first, total: turn.upperBound,
                              entries: (first..<turn.upperBound).map {
                                  TranscriptEntry(kind: .agentMessage(messageID: nil, text: "\($0)"))
                              })
    }

    /// The chat that opened on a phone mid-sentence (#1130): a turn of 42 entries, a
    /// page of 31, and the ask and the reply's start left on the Mac. The turn comes
    /// whole, in one more request.
    @Test func aTurnLongerThanThePageIsTakenWhole() async throws {
        let turn = 3342..<3384
        var asked: [Int] = []
        let loaded = try await ChatOpening.load(
            limit: 31,
            turns: { TurnsPage(turns: [], firstTurn: 12, openStart: turn.lowerBound) },
            transcript: { from, limit in asked.append(limit); return self.tail(of: turn, from: from, limit: limit) })
        #expect(asked == [31, 42])
        #expect(loaded.page.firstIndex == turn.lowerBound)
        #expect(loaded.page.entries.count == turn.count)
    }

    @Test func aTurnThatFitsIsAskedForOnce() async throws {
        let turn = 100..<120
        var asked: [Int] = []
        let loaded = try await ChatOpening.load(
            limit: 31,
            turns: { TurnsPage(turns: [], firstTurn: 1, openStart: turn.lowerBound) },
            transcript: { from, limit in asked.append(limit); return self.tail(of: turn, from: from, limit: limit) })
        #expect(asked == [31])
        #expect(loaded.page.firstIndex == turn.lowerBound)
    }

    /// Past `wholeTurn` the end of it is enough: the rest comes as the reader scrolls.
    @Test func aVeryLongTurnStopsAtTheCeiling() async throws {
        let turn = 0..<5_000
        var asked: [Int] = []
        let loaded = try await ChatOpening.load(
            limit: 31,
            turns: { TurnsPage(turns: [], firstTurn: 0, openStart: turn.lowerBound) },
            transcript: { from, limit in asked.append(limit); return self.tail(of: turn, from: from, limit: limit) })
        #expect(asked == [31, ChatOpening.wholeTurn])
        #expect(loaded.page.entries.count == ChatOpening.wholeTurn)
    }

    /// Without turns the page is the end of the whole transcript, not a cut turn.
    @Test func noTurnsMeansNoSecondAsk() async throws {
        struct Broken: Error {}
        var asked: [Int] = []
        _ = try await ChatOpening.load(
            limit: 31,
            turns: { throw Broken() },
            transcript: { from, limit in asked.append(limit); return self.tail(of: 0..<900, from: from, limit: limit) })
        #expect(asked == [31])
    }

    @Test func aTranscriptThatDoesNotComeThrows() async {
        struct Lost: Error {}
        await #expect(throws: Lost.self) {
            _ = try await ChatOpening.load(turns: { TurnsPage(turns: [], firstTurn: 0, openStart: 0) },
                                           transcript: { _, _ in throw Lost() })
        }
    }

    /// Only the host saying it has no such session is an answer that it has gone; a
    /// failure to reach it, or an answer late, is not (#2743).
    @Test func onlyNoSuchAgentSaysGone() {
        struct Lost: Error {}
        #expect(ChatOpening.saysGone(JSONRPCError(code: DaemonAPI.Failure.noSuchAgent, message: "no agent")))
        #expect(!ChatOpening.saysGone(JSONRPCError(code: DaemonAPI.Failure.hostOffline, message: "offline")))
        #expect(!ChatOpening.saysGone(Lost()))
    }
}
