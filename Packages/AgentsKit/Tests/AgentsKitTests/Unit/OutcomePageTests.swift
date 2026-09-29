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
            return entry.text
        case .toolRun(_, let calls)?: return calls.last?.turnLine
        case nil: return nil
        }
    }

    @Test func aTurnIsItsAskItsBlocksAndItsLast() {
        let turns = TranscriptEntry.display([ask("Fix it"), said("Looking."), call("1", "List files"),
                                             call("2"), said("Fixed.")]).turns()
        #expect(turns.count == 1)
        #expect(text(turns[0].ask) == "Fix it")
        #expect(turns[0].blocks.count == 3)
        #expect(text(turns[0].last) == "Fixed.")
    }

    @Test func aToolCallWithoutADescriptionUsedATool() {
        let turns = TranscriptEntry.display([ask("Go"), said("First"), call("1")]).turns()
        #expect(text(turns[0].last) == "Used a tool")
        let described = TranscriptEntry.display([ask("Go"), call("1", "Run the tests")]).turns()
        #expect(text(described[0].last) == "Run the tests")
    }

    @Test func eachAskStartsATurn() {
        let turns = TranscriptEntry.display([ask("One"), said("Done one"), ask("Two"), call("1", "Read")]).turns()
        #expect(turns.map { text($0.ask) } == ["One", "Two"])
        #expect(turns.map { text($0.last) } == ["Done one", "Read"])
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
