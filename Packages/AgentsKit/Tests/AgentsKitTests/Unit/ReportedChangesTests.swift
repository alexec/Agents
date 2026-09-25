import Foundation
import Testing
@testable import AgentsKitCore

/// Which diffs in a transcript are edits (035 research R1).
@Suite("Reported changes")
struct ReportedChangesTests {
    private func call(_ id: String, status: String? = "pending", diffs: [ToolCallContent.Diff] = [],
                      rawInput: JSONValue? = nil, update: Bool = true) -> TranscriptEntry {
        let tool = ToolCall(toolCallID: id, title: "Edit", status: status,
                            content: diffs.map { .diff($0) }, rawInput: rawInput)
        return TranscriptEntry(kind: update ? .toolCallUpdate(tool) : .toolCall(tool))
    }

    private func diff(_ path: String, _ old: String?, _ new: String) -> ToolCallContent.Diff {
        .init(path: path, oldText: old, newText: new)
    }

    /// Claude's order: begun, a diff from the input, a diff after it ran, done.
    private func claudeEdit(_ id: String, _ path: String, old: String?, new: String,
                            ending: String = "completed") -> [TranscriptEntry] {
        [call(id, update: false),
         call(id, status: nil, diffs: [diff(path, nil, new)]),
         call(id, status: nil, diffs: [diff(path, old, new)]),
         call(id, status: ending)]
    }

    @Test func aWriteOverAFileIsOneEditAndNotANewFile() {
        let fold = ReportedChanges(entries: claudeEdit("a", "/w/a.swift", old: "x\n", new: "y\n"))
        #expect(fold.edits.count == 1)
        #expect(fold.edits.first?.oldText == "x\n")
    }

    @Test func aFailedCallIsNoEdit() {
        let fold = ReportedChanges(entries: claudeEdit("a", "/w/a.swift", old: "x", new: "y",
                                                       ending: "failed"))
        #expect(fold.edits.isEmpty)
        #expect(fold.inProgress.isEmpty)
        #expect(fold.reportsEdits)
    }

    @Test func anUnfinishedCallIsInProgressAndNotAnEdit() {
        let entries = Array(claudeEdit("a", "/w/a.swift", old: "x", new: "y").dropLast())
        let fold = ReportedChanges(entries: entries)
        #expect(fold.edits.isEmpty)
        #expect(fold.inProgress == ["/w/a.swift"])
    }

    @Test func aCallWithTwoDiffsIsTwoEditsInOrder() {
        let fold = ReportedChanges(entries: [
            call("a", status: "completed",
                 diffs: [diff("/w/a.swift", "1", "2"), diff("/w/a.swift", "3", "4")]),
        ])
        #expect(fold.edits.map(\.index) == [0, 1])
        #expect(fold.edits.map(\.newText) == ["2", "4"])
    }

    @Test func editsAreInTheOrderEachCallFirstCarriedADiff() {
        // b starts first and finishes last; it is still first.
        let fold = ReportedChanges(entries: [
            call("b", status: nil, diffs: [diff("/w/b.swift", nil, "b")]),
            call("a", status: nil, diffs: [diff("/w/a.swift", nil, "a")]),
            call("a", status: "completed"),
            call("b", status: "completed"),
        ])
        #expect(fold.edits.map(\.toolCallID) == ["b", "a"])
    }

    @Test func filesAreInTheOrderOfTheirFirstEdit() {
        let fold = ReportedChanges(entries:
            claudeEdit("1", "/w/a.swift", old: "1", new: "2")
            + claudeEdit("2", "/w/b.md", old: nil, new: "new")
            + claudeEdit("3", "/w/a.swift", old: "2", new: "3"))
        #expect(fold.byFile.map(\.path) == ["/w/a.swift", "/w/b.md"])
        #expect(fold.byFile.first?.edits.count == 2)
        #expect(fold.byFile.last?.edits.first?.oldText == nil)
    }

    @Test func foldingOneAtATimeIsFoldingAllAtOnce() {
        let entries = claudeEdit("1", "/w/a.swift", old: "1", new: "2")
            + claudeEdit("2", "/w/b.md", old: nil, new: "new", ending: "failed")
            + claudeEdit("3", "/w/a.swift", old: "2", new: "3")
        var stepped = ReportedChanges()
        for (index, entry) in entries.enumerated() { stepped.absorb(entry, at: index) }
        #expect(stepped == ReportedChanges(entries: entries))
        #expect(stepped.edits == ReportedChanges(entries: entries).edits)
    }

    @Test func replaceAllIsKept() {
        let fold = ReportedChanges(entries: [
            call("a", update: false),
            call("a", status: "completed", diffs: [diff("/w/a.swift", "x", "y")],
                 rawInput: ["replace_all": true]),
        ])
        #expect(fold.edits.first?.replaceAll == true)
    }

    @Test func aPathIsOneFileHoweverItIsSpelled() throws {
        let folder = URL(filePath: NSTemporaryDirectory()).appending(path: "rc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let real = folder.resolvingSymlinksInPath().appending(path: "a.swift").path
        let spelled = folder.appending(path: "./a.swift").path
        let fold = ReportedChanges(entries:
            claudeEdit("1", real, old: "1", new: "2") + claudeEdit("2", spelled, old: "2", new: "3"))
        #expect(fold.byFile.count == 1)
    }

    // MARK: SC-002

    private var fixtures: URL {
        URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Fixtures")
    }

    private struct Expected: Decodable, Equatable {
        var path: String
        var toolCallID: String
        var index: Int
        var isNew: Bool
    }

    @Test func aRealClaudeTranscriptGivesExactlyItsEdits() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = ACP.timestamp(from: text) else {
                throw DecodingError.dataCorruptedError(in: try decoder.singleValueContainer(),
                                                       debugDescription: "not a date")
            }
            return date
        }
        let lines = try String(contentsOf: fixtures.appending(path: "claude-edits.jsonl"),
                               encoding: .utf8).split(separator: "\n")
        let entries = try lines.map { try decoder.decode(TranscriptEntry.self, from: Data($0.utf8)) }
        let expected = try JSONDecoder().decode(
            [Expected].self,
            from: Data(contentsOf: fixtures.appending(path: "claude-edits.expected.json")))

        let got = ReportedChanges(entries: entries).edits.map {
            Expected(path: $0.path, toolCallID: $0.toolCallID, index: $0.index, isNew: $0.oldText == nil)
        }
        #expect(expected.count >= 50)
        #expect(got.count == expected.count)
        #expect(got == expected)
        #expect(Set(got.map { "\($0.toolCallID)#\($0.index)" }).count == got.count, "none duplicated")
    }
}
