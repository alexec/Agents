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

    @Test func noCardsIsTheConversationAsItIs() throws {
        let stretches = place([ask("Fix it", 0), said("Done.", 1)], [])
        try #require(stretches.count == 1)
        #expect(words(stretches[0]) == [["[Fix it]", "Done."]])
    }

    @Test func aCardNewerThanEverythingIsAtTheEnd() throws {
        let stretches = place([ask("Fix it", 0), said("Looking.", 1)], [Card(name: "allow", at: 5)])
        try #require(stretches.count == 1)
        #expect(words(stretches[0]) == [["[Fix it]", "Looking."]])
        #expect(stretches[0].cards.map(\.name) == ["allow"])
    }

    /// What came after the question is drawn below it, the turn cut in two.
    @Test func laterOutputGoesBelowTheCardInTheSameTurn() throws {
        let stretches = place([ask("Fix it", 0), said("Looking.", 1), call("1", 2), said("More.", 6)],
                              [Card(name: "allow", at: 3)])
        try #require(stretches.count == 2)
        #expect(words(stretches[0]) == [["[Fix it]", "Looking.", "run"]])
        #expect(stretches[0].cards.map(\.name) == ["allow"])
        #expect(words(stretches[1]) == [["More."]])
        // The part after the card is named by its first item, not the turn's ask.
        let before = try #require(stretches[0].turns.first), after = try #require(stretches[1].turns.first)
        #expect(before.id != after.id)
    }

    /// A run of tool calls keeps no time and stays with the call that raised the question.
    @Test func aRunWithNoTimeStaysBeforeACardAfterIt() throws {
        let stretches = place([ask("Fix it", 0), said("Looking.", 1), call("1", 2), call("2", 2), said("Ok.", 9)],
                              [Card(name: "allow", at: 4)])
        try #require(stretches.count >= 2)
        #expect(words(stretches[0]) == [["[Fix it]", "Looking.", "run"]])
        #expect(words(stretches[1]) == [["Ok."]])
    }

    @Test func aLaterTurnGoesBelowTheCardWhole() throws {
        let stretches = place([ask("Fix it", 0), said("Done.", 1), ask("Next", 10), said("Ok.", 11)],
                              [Card(name: "keep", at: 5)])
        try #require(stretches.count >= 2)
        #expect(words(stretches[0]) == [["[Fix it]", "Done."]])
        #expect(stretches[0].cards.map(\.name) == ["keep"])
        #expect(words(stretches[1]) == [["[Next]", "Ok."]])
        let later = try #require(stretches[1].turns.first)
        #expect(later.id == later.ask?.id)
    }

    /// A card from before everything in hand sits at the top.
    @Test func aCardOlderThanEverythingIsAtTheTop() throws {
        let stretches = place([ask("Fix it", 10), said("Done.", 11)], [Card(name: "keep", at: 1)])
        try #require(stretches.count == 2)
        #expect(stretches[0].turns.isEmpty)
        #expect(stretches[0].cards.map(\.name) == ["keep"])
        #expect(words(stretches[1]) == [["[Fix it]", "Done."]])
    }

    /// Each card at its own place; two at one place together, in the order given.
    @Test func eachCardAtItsOwnPlace() throws {
        let stretches = place([ask("Fix it", 0), said("One.", 1), said("Two.", 5), ask("Next", 10)],
                              [Card(name: "form", at: 7), Card(name: "allow", at: 3), Card(name: "keep", at: 3)])
        try #require(stretches.count >= 3)
        #expect(stretches.map { $0.cards.map(\.name) } == [["allow", "keep"], ["form"], []])
        #expect(words(stretches[0]) == [["[Fix it]", "One."]])
        #expect(words(stretches[1]) == [["Two."]])
        #expect(words(stretches[2]) == [["[Next]"]])
    }

    /// Asked right after the person's ask: the turn's start is above, the rest below.
    @Test func aCardRightAfterTheAsk() throws {
        let stretches = place([ask("Fix it", 0), said("Ok.", 5)], [Card(name: "allow", at: 2)])
        try #require(stretches.count >= 2)
        #expect(words(stretches[0]) == [["[Fix it]"]])
        #expect(words(stretches[1]) == [["Ok."]])
    }

    /// The host's own record of the question comes a moment after it, and stays above the card.
    @Test func theQuestionsOwnRecordIsAboveIt() throws {
        let record = TranscriptEntry(at: time(3).addingTimeInterval(0.002),
                                     kind: .agentMessage(messageID: "asked", text: "Asked."))
        let stretches = place([ask("Fix it", 0), said("Looking.", 1), record, said("Ok.", 9)], [Card(name: "allow", at: 3)])
        try #require(stretches.count >= 2)
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

    /// Where a conversation opens (#1287): a card asked before the end, else the last turn's
    /// ask when unread, else the end. A card at the end is the end.
    @Test func aConversationOpensWhereTheReaderNeedsIt() throws {
        let entries = [ask("A", 0), said("a1", 1), ask("B", 6), said("b1", 7)]
        let none = place(entries, [])
        #expect(none.openingPlace(unread: false) == nil)
        let lastAsk = try #require(none.last?.turns.last)
        #expect(none.openingPlace(unread: true) == .turn(lastAsk.id))
        // Asked in the middle, with B after it: the card, unread or not.
        let middle = place(entries, [Card(name: "allow", at: 3)])
        #expect(middle.openingPlace(unread: true) == .cards(stretch: 0))
        // Asked after everything: the end, which is where the card is.
        #expect(place(entries, [Card(name: "allow", at: 20)]).openingPlace(unread: true) == nil)
        // A long last turn's tail in hand, a row with no ask: its ask is before the page.
        let tail = ChatTurn(id: UUID(), ask: nil, items: [TranscriptItem.entry(said("b2", 8))])
        let withTail = [ChatStretch<Card>(turns: none[0].turns + [tail], cards: [])]
        #expect(withTail.openingPlace(unread: true) == .askBefore)
        #expect(withTail.openingPlace(unread: false) == nil)
    }
}
