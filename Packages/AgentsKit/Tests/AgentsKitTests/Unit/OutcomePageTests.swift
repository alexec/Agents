import Foundation
import Testing
@testable import AgentsKitCore

@Suite("A conversation as turns")
struct OutcomePageTests {
    private func ask(_ text: String) -> TranscriptEntry {
        TranscriptEntry(kind: .userMessage(text))
    }

    private func said(_ text: String) -> TranscriptEntry {
        TranscriptEntry(kind: .agentMessage(messageID: nil, text: text))
    }

    private func call(_ id: String, _ description: String? = nil) -> TranscriptEntry {
        TranscriptEntry(kind: .toolCall(ToolCall(
            toolCallID: id, title: "Bash " + id,
            rawInput: description.map { .object(["description": .string($0), "command": .string("ls")]) }
                ?? .object(["command": .string("ls")]))))
    }

    private func text(_ item: TranscriptItem?) -> String? {
        switch item {
        case .entry(let entry)?:
            if case .toolCall(let call) = entry.kind { return call.turnLine }
            if case .workReported(let report) = entry.kind { return report.message }
            return entry.text
        case .toolRun(_, let calls)?: return calls.last?.turnLine
        case nil: return nil
        }
    }

    private func report(_ message: String) -> TranscriptEntry {
        TranscriptEntry(kind: .workReported(WorkReport(outcome: .done, message: message, at: Date())))
    }

    private func turn(_ entries: [TranscriptEntry]) -> ChatTurn {
        TranscriptEntry.display(entries).turns()[0]
    }

    @Test func aTurnIsItsAskAndEverythingAfterIt() throws {
        let turns = TranscriptEntry.display([ask("Fix it"), said("Looking."), call("1", "List files"),
                                             call("2"), said("Fixed.")]).turns()
        try #require(turns.count == 1)
        #expect(text(turns[0].ask) == "Fix it")
        #expect(turns[0].items.count == 3)
    }

    @Test func aFinishedTurnsOutcomeIsItsReplyAndItsReport() {
        let parts = TurnParts(turn([ask("Fix it"), said("Looking."), call("1", "List files"),
                                    call("2"), said("Fixed."), report("It works")]).items, isLive: false)
        #expect(parts.outcome.map(text) == ["Fixed.", "It works"])
        // "Looking." and the two calls.
        #expect(parts.stepCount == 3)
        #expect(parts.live == nil)
    }

    @Test func aFailureWithNoReplyEndsOnTheFailure() {
        let stopped = TranscriptEntry(kind: .stateChanged(.stopped, reason: .rateLimited))
        let parts = TurnParts(turn([ask("Push"), call("1", "Push to origin"), stopped]).items, isLive: false)
        #expect(parts.outcome.count == 1)
        guard case .entry(let entry)? = parts.outcome.first, case .stateChanged = entry.kind else {
            Issue.record("no failure in the outcome"); return
        }
        #expect(parts.stepCount == 1)
    }

    @Test func aFinishedTurnsReplyIsItsLastMessageWhereverItFalls() {
        let parts = TurnParts(turn([ask("Go"), said("Done, pushing."), call("1", "Push")]).items, isLive: false)
        #expect(parts.outcome.map(text) == ["Done, pushing."])
    }

    @Test func aRunningTurnShowsItsLatestStepUntilItReplies() {
        let working = TurnParts(turn([ask("Go"), said("First"), call("1", "Run the tests")]).items, isLive: true)
        #expect(working.outcome.isEmpty)
        #expect(text(working.live) == "Run the tests")
        let replying = TurnParts(turn([ask("Go"), call("1", "Run the tests"), said("All green")]).items, isLive: true)
        #expect(replying.outcome.map(text) == ["All green"])
        #expect(replying.live == nil)
    }

    @Test func theReportComesLastAndAClosingLineJoinsTheReply() {
        let parts = TurnParts(turn([ask("Go"), call("1", "Read"), said("It says hi."),
                                    report("Read it"), said("Done.")]).items, isLive: false)
        #expect(parts.outcome.map(text) == ["It says hi.", "Done.", "Read it"])
        #expect(parts.stepCount == 1)
    }

    @Test func aPassingLineAfterAFinishedTurnIsNotAStep() {
        let back = TranscriptEntry(kind: .runtimeNote("Picked the conversation back up."))
        let parts = TurnParts(turn([ask("Go"), call("1", "Read"), said("It says hi."),
                                    report("Read it"), said("Done."), back]).items, isLive: false)
        #expect(parts.outcome.map(text) == ["It says hi.", "Done.", "Read it"])
        #expect(parts.stepCount == 1)
    }

    @Test func thinkingIsNotAStep() {
        let thought = TranscriptEntry(kind: .agentThought(messageID: nil, text: "Hmm"))
        let parts = TurnParts(turn([ask("Go"), thought, call("1", "Read"), said("Done")]).items, isLive: false)
        #expect(parts.stepCount == 1)
    }

    @Test func aSummaryKeepsTheOutcomeAndTheStepCount() {
        let summary = TurnSummary.of([ask("Go"), said("Looking"), call("1", "List files"),
                                      said("Found it"), report("Found")], start: 0)
        #expect(summary.outcome?.map { text(.entry($0)) } == ["Found it", "Found"])
        #expect(summary.steps == 2)
        let drawn = ChatTurn(summary)
        #expect(drawn.isSummaryOnly)
        #expect(drawn.storedStepCount == 2)
    }

    @Test func aSummaryKeepsTheAskAndACutDownLastBlock() {
        let entries = [ask("Go"), said("Looking"), call("1", "List files")]
        let summary = TurnSummary.of(entries, start: 10)
        #expect(summary.start == 10 && summary.end == 13)
        #expect(summary.ask?.text == "Go")
        guard case .toolCall(let kept)? = summary.last?.kind else { Issue.record("no tool call"); return }
        #expect(kept.rawInput == .object(["description": .string("List files")]))
        #expect(kept.turnLine == "List files")
    }

    @Test func splittingLeavesTheLastTurnOpen() {
        let entries = [ask("One"), said("a"), ask("Two"), said("b"), ask("Three")]
        let (closed, openStart) = TurnSummary.split(entries, start: 5)
        #expect(closed.map(\.start) == [5, 7])
        #expect(closed.map(\.end) == [7, 9])
        #expect(openStart == 9)
        #expect(closed.map { $0.last?.text } == ["a", "b"])
    }
}
