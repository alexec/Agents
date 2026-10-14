import Foundation
import Testing
@testable import AgentsKitCore

@Suite("A waiting card where it was asked")
struct WaitingCardPlacesTests {
    private let start = Date(timeIntervalSince1970: 1_000)

    private func time(_ second: Int) -> Date { start.addingTimeInterval(TimeInterval(second)) }

    private func ask(_ text: String, _ second: Int) -> TranscriptEntry {
        TranscriptEntry(at: time(second), kind: .userMessage(text))
    }

    private func said(_ text: String, _ second: Int) -> TranscriptEntry {
        TranscriptEntry(at: time(second), kind: .agentMessage(messageID: text, text: text))
    }

    private func call(_ id: String, _ second: Int) -> TranscriptEntry {
        TranscriptEntry(at: time(second), kind: .toolCall(ToolCall(toolCallID: id, title: "Bash " + id)))
    }

    private struct Card { let name: String; let at: Int }

    private func place(_ entries: [TranscriptEntry], _ cards: [Card]) -> [ChatStretch<Card>] {
        TranscriptEntry.display(entries).turns().placing(cards) { time($0.at) }
    }

    /// The turns of each stretch as the first word of each item, the ask in brackets.
    private func words(_ stretch: ChatStretch<Card>) -> [[String]] {
        stretch.turns.map { turn in
            (turn.ask.map { ["[" + text($0) + "]"] } ?? []) + turn.items.map(text)
        }
    }

    private func text(_ item: TranscriptItem) -> String {
        if case .entry(let entry) = item { return entry.text ?? "" }
        return "run"
    }

    @Test func noCardsIsTheConversationAsItIs() {
        let stretches = place([ask("Fix it", 0), said("Done.", 1)], [])
        #expect(stretches.count == 1)
        #expect(words(stretches[0]) == [["[Fix it]", "Done."]])
    }

    @Test func aCardNewerThanEverythingIsAtTheEnd() {
        let stretches = place([ask("Fix it", 0), said("Looking.", 1)], [Card(name: "allow", at: 5)])
        #expect(stretches.count == 1)
        #expect(words(stretches[0]) == [["[Fix it]", "Looking."]])
        #expect(stretches[0].cards.map(\.name) == ["allow"])
    }

    /// What came after the question is drawn below it, the turn cut in two.
    @Test func laterOutputGoesBelowTheCardInTheSameTurn() {
        let stretches = place([ask("Fix it", 0), said("Looking.", 1), call("1", 2), said("More.", 6)],
                              [Card(name: "allow", at: 3)])
        #expect(stretches.count == 2)
        #expect(words(stretches[0]) == [["[Fix it]", "Looking.", "run"]])
        #expect(stretches[0].cards.map(\.name) == ["allow"])
        #expect(words(stretches[1]) == [["More."]])
        // The part after the card is named by its first item, not the turn's ask.
        #expect(stretches[0].turns[0].id != stretches[1].turns[0].id)
    }

    /// A run of tool calls keeps no time and stays with the call that raised the question.
    @Test func aRunWithNoTimeStaysBeforeACardAfterIt() {
        let stretches = place([ask("Fix it", 0), said("Looking.", 1), call("1", 2), call("2", 2), said("Ok.", 9)],
                              [Card(name: "allow", at: 4)])
        #expect(words(stretches[0]) == [["[Fix it]", "Looking.", "run"]])
        #expect(words(stretches[1]) == [["Ok."]])
    }

    @Test func aLaterTurnGoesBelowTheCardWhole() {
        let stretches = place([ask("Fix it", 0), said("Done.", 1), ask("Next", 10), said("Ok.", 11)],
                              [Card(name: "keep", at: 5)])
        #expect(words(stretches[0]) == [["[Fix it]", "Done."]])
        #expect(stretches[0].cards.map(\.name) == ["keep"])
        #expect(words(stretches[1]) == [["[Next]", "Ok."]])
        #expect(stretches[1].turns[0].id == stretches[1].turns[0].ask?.id)
    }

    /// A card from before everything in hand sits at the top.
    @Test func aCardOlderThanEverythingIsAtTheTop() {
        let stretches = place([ask("Fix it", 10), said("Done.", 11)], [Card(name: "keep", at: 1)])
        #expect(stretches.count == 2)
        #expect(stretches[0].turns.isEmpty)
        #expect(stretches[0].cards.map(\.name) == ["keep"])
        #expect(words(stretches[1]) == [["[Fix it]", "Done."]])
    }

    /// Each card at its own place; two at one place together, in the order given.
    @Test func eachCardAtItsOwnPlace() {
        let stretches = place([ask("Fix it", 0), said("One.", 1), said("Two.", 5), ask("Next", 10)],
                              [Card(name: "form", at: 7), Card(name: "allow", at: 3), Card(name: "keep", at: 3)])
        #expect(stretches.map { $0.cards.map(\.name) } == [["allow", "keep"], ["form"], []])
        #expect(words(stretches[0]) == [["[Fix it]", "One."]])
        #expect(words(stretches[1]) == [["Two."]])
        #expect(words(stretches[2]) == [["[Next]"]])
    }

    /// Asked right after the person's ask: the turn's start is above, the rest below.
    @Test func aCardRightAfterTheAsk() {
        let stretches = place([ask("Fix it", 0), said("Ok.", 5)], [Card(name: "allow", at: 2)])
        #expect(words(stretches[0]) == [["[Fix it]"]])
        #expect(words(stretches[1]) == [["Ok."]])
    }

    /// The host's own record of the question comes a moment after it, and stays above the card.
    @Test func theQuestionsOwnRecordIsAboveIt() {
        let record = TranscriptEntry(at: time(3).addingTimeInterval(0.002),
                                     kind: .agentMessage(messageID: "asked", text: "Asked."))
        let stretches = place([ask("Fix it", 0), said("Looking.", 1), record, said("Ok.", 9)], [Card(name: "allow", at: 3)])
        #expect(words(stretches[0]) == [["[Fix it]", "Looking.", "Asked."]])
        #expect(stretches[0].cards.map(\.name) == ["allow"])
        #expect(words(stretches[1]) == [["Ok."]])
    }

    /// Cut and put back together, nothing is lost or drawn twice.
    @Test func everyItemIsDrawnOnce() {
        let entries = [ask("A", 0), said("a1", 1), call("1", 2), said("a2", 4), ask("B", 6), said("b1", 7),
                       said("b2", 9)]
        let whole = TranscriptEntry.display(entries).turns()
        let stretches = place(entries, [Card(name: "x", at: 3), Card(name: "y", at: 8), Card(name: "z", at: 20)])
        let ids = stretches.flatMap(\.turns).flatMap { ($0.ask.map { [$0.id] } ?? []) + $0.items.map(\.id) }
        #expect(ids == whole.flatMap { ($0.ask.map { [$0.id] } ?? []) + $0.items.map(\.id) })
        #expect(stretches.last?.cards.map(\.name) == ["z"])
    }
}
