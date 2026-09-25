@testable import CodeText
import Testing

/// The changed part of a changed line (041 FR-009, research R5).
struct WordDiffTests {
    static func marked(_ line: String, _ ranges: [Range<Int>]) -> [String] {
        let utf16 = Array(line.utf16)
        return ranges.map { String(decoding: utf16[$0], as: UTF16.self) }
    }

    @Test func onlyTheChangedNumberIsMarked() {
        let rows = LineDiff.rows(old: "let total = 10", new: "let total = 12")
        #expect(Self.marked("let total = 10", rows[0].changed) == ["10"])
        #expect(Self.marked("let total = 12", rows[1].changed) == ["12"])
    }

    @Test func anIndentationChangeMarksTheWhitespace() {
        let rows = LineDiff.rows(old: "  return x", new: "    return x")
        #expect(Self.marked("  return x", rows[0].changed) == ["  "])
        #expect(Self.marked("    return x", rows[1].changed) == ["    "])
    }

    @Test func aRewriteGetsNoWordMarks() {
        let rows = LineDiff.rows(old: "let a = compute(x, y)", new: "print(\"done\")")
        #expect(rows.allSatisfy { $0.changed.isEmpty })
    }

    @Test func aLongLineGetsNoWordMarks() {
        let long = String(repeating: "a ", count: 501)  // 1,002 characters
        let rows = LineDiff.rows(old: long, new: long + "b")
        #expect(rows.allSatisfy { $0.changed.isEmpty })
    }

    @Test func aBlockOfMoreThanTwoHundredPairsGetsNoWordMarks() {
        let old = (0..<201).map { "let v\($0) = 1" }.joined(separator: "\n")
        let new = (0..<201).map { "let v\($0) = 2" }.joined(separator: "\n")
        #expect(LineDiff.rows(old: old, new: new).allSatisfy { $0.changed.isEmpty })
    }

    @Test func pairsAreRemovedIWithAddedIAndTheRestUnpaired() {
        let rows = LineDiff.rows(old: "a = 1\nb = 1", new: "a = 2\nb = 2\nc = 2")
        #expect(LineDiffTests.kinds(rows) == "--+++")
        #expect(!rows[0].changed.isEmpty && !rows[2].changed.isEmpty)
        #expect(!rows[1].changed.isEmpty && !rows[3].changed.isEmpty)
        #expect(rows[4].changed.isEmpty)
    }

    @Test func rangesAreUTF16AndLandOnWholeCharacters() {
        let old = "let café = \"👩‍👩‍👧 one\""
        let new = "let café = \"👩‍👩‍👧 two\""
        let rows = LineDiff.rows(old: old, new: new)
        #expect(Self.marked(old, rows[0].changed) == ["one"])
        #expect(Self.marked(new, rows[1].changed) == ["two"])
    }
}
