import Foundation
import Testing
@testable import AgentsKitCore

/// The Changed files card at the end of a turn, and its undo (#3437).
@Suite("Turn changes")
struct TurnChangesTests {
    static let changes = TurnChanges(turn: UUID(), files: [
        TurnChangedFile(path: "/r/a.txt", relativePath: "a.txt", state: .modified),
        TurnChangedFile(path: "/r/new.txt", relativePath: "new.txt", state: .added),
    ], more: 3, before: "t1", after: "t2")

    @Test func theCardIsAnOutcomeAndCodes() throws {
        let card = TranscriptEntry(kind: .turnChanged(Self.changes))
        let decoded = try JSONDecoder().decode(TranscriptEntry.self, from: JSONEncoder().encode(card))
        #expect(decoded.kind == card.kind)
        #expect(TranscriptEntry.display([card]).last?.isOutcome == true)
        #expect(TurnChangesWords.title(Self.changes) == "Changed 5 files")
        // The Object card's quiet line names the files (#5035).
        #expect(TurnChangesWords.names(Self.changes) == "a.txt, new.txt and 3 more")
        #expect(TurnChangesWords.names(TurnChanges(turn: UUID(), files: Self.changes.files, before: "t1", after: "t2"))
            == "a.txt and new.txt")
    }

    /// The undo is said on the card, and is no line of its own.
    @Test func anUndoIsSaidOnTheCard() throws {
        let card = TranscriptEntry(kind: .turnChanged(Self.changes))
        let undo = TurnUndo(turn: Self.changes.turn, putBack: ["/r/a.txt"])
        let undone = TranscriptEntry(kind: .turnUndone(undo))
        let decoded = try JSONDecoder().decode(TranscriptEntry.self, from: JSONEncoder().encode(undone))
        #expect(decoded.kind == undone.kind)
        let items = TranscriptEntry.display([card, undone])
        #expect(items.count == 1)
        guard case .entry(let drawn) = items.first, case .turnChanged(let changes) = drawn.kind else {
            Issue.record("not the turn's card")
            return
        }
        #expect(changes.undone == undo)
        #expect(TurnChangesWords.undone(undo) == "Undone: 1 file is back as it was before this turn.")
        // One whose card is on an earlier page is left out.
        #expect(TranscriptEntry.display([undone]).isEmpty)
    }

    @Test func theQuestionNamesTheFiles() {
        #expect(TurnChangesWords.confirmMessage(["/r/a.txt", "/r/b.txt"])
            == "a.txt and b.txt changed again after this turn. Undo puts them back as before the turn, and the later changes go too.")
        #expect(TurnChangesWords.cannotUndo(["/elsewhere/x.txt"])
            == "Undo cannot put back x.txt: it is outside the folder or ignored by git.")
    }
}
