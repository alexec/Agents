import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// Whether a file's reported edits account for what is on disk (035 research R5).
@Suite("Replaying reported edits")
struct EditReplayTests {
    private func edit(_ old: String?, _ new: String, all: Bool = false) -> ReportedEdit {
        ReportedEdit(path: "/w/a.swift", oldText: old, newText: new, toolCallID: UUID().uuidString,
                     index: 0, entryIndex: 0, replaceAll: all, at: Date())
    }

    @Test func twoEditsMakeWhatIsOnDisk() {
        let edits = [edit("one", "ONE"), edit("three", "THREE")]
        #expect(EditReplay.accounts(for: edits, start: "one\ntwo\nthree\n", now: "ONE\ntwo\nTHREE\n"))
    }

    @Test func somethingElseOnDiskIsBeyondThem() {
        let edits = [edit("one", "ONE")]
        #expect(!EditReplay.accounts(for: edits, start: "one\ntwo\n", now: "ONE\ntwo\nformatted\n"))
    }

    @Test func aWriteReplacesTheWholeFile() {
        let edits = [edit("old\nfile\n", "new\nfile\n")]
        #expect(EditReplay.accounts(for: edits, start: "old\nfile\n", now: "new\nfile\n"))
    }

    @Test func replaceAllReplacesEveryOccurrenceAndOtherwiseTheFirst() {
        #expect(EditReplay.accounts(for: [edit("x", "y", all: true)], start: "x x x", now: "y y y"))
        #expect(EditReplay.accounts(for: [edit("x", "y")], start: "x x x", now: "y x x"))
    }

    @Test func aPassageThatIsNotThereStopsTheReplay() {
        #expect(!EditReplay.accounts(for: [edit("gone", "here")], start: "nothing", now: "nothing"))
    }

    @Test func aDroppedLastNewlineIsNotSomethingElse() {
        #expect(EditReplay.accounts(for: [edit(nil, "hello")], start: "", now: "hello\n"))
    }

    @Test func aNewFileStartsFromNothing() {
        let edits = [edit(nil, "made\n"), edit("made", "made twice")]
        #expect(EditReplay.accounts(for: edits, start: "ignored", now: "made twice\n"))
    }
}
