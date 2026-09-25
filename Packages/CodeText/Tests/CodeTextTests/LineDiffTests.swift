@testable import CodeText
import Foundation
import Testing

/// An edit as a real line diff (041 FR-008, research R5; contract invariant 3).
struct LineDiffTests {
    static func kinds(_ rows: [DiffRow]) -> String {
        rows.map { switch $0.kind { case .context: " "; case .removed: "-"; case .added: "+" } }
            .joined()
    }

    @Test func identicalTextsAreAllContext() {
        let text = "a\nb\nc"
        #expect(Self.kinds(LineDiff.rows(old: text, new: text)) == "   ")
    }

    @Test func oneChangedLineInFortyIsOneRemovedAndOneAdded() {
        let old = (1...40).map { "let v\($0) = \($0)" }
        var new = old
        new[19] = "let v20 = 2000"
        let rows = LineDiff.rows(old: old.joined(separator: "\n"), new: new.joined(separator: "\n"))
        #expect(rows.count == 41)
        #expect(rows.filter { $0.kind == .context }.count == 39)
        let changed = rows.enumerated().filter { $0.element.kind != .context }
        #expect(changed.map(\.element.kind) == [.removed, .added])
        #expect(changed[0].offset + 1 == changed[1].offset)
        #expect(changed[0].element.text == "let v20 = 20")
        #expect(changed[1].element.text == "let v20 = 2000")
    }

    @Test(arguments: [nil, ""] as [String?])
    func aNewFileIsAllAddedWithNoWordMarks(old: String?) {
        let rows = LineDiff.rows(old: old, new: "one\ntwo\nthree")
        #expect(Self.kinds(rows) == "+++")
        #expect(rows.allSatisfy { $0.changed.isEmpty })
        #expect(Folds.of(rows).isEmpty)
    }

    @Test func aPureInsertionHasNoRemovedRows() {
        let rows = LineDiff.rows(old: "a\nb\nc", new: "a\nb\nnew\nc")
        #expect(Self.kinds(rows) == "  + ")
    }

    @Test func removedRowsComeBeforeAddedRowsInABlock() {
        let rows = LineDiff.rows(old: "a\nx\ny\nb", new: "a\np\nq\nr\nb")
        #expect(Self.kinds(rows) == " --+++ ")
    }

    /// The rows rebuild both texts, for many random edits.
    @Test func rowsRebuildBothSides() throws {
        let sample = try ColourerTests.sample("sample.swift")
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var generator = SeededGenerator(seed: 41)
        for _ in 0..<200 {
            let start = Int.random(in: 0..<sample.count - 10, using: &generator)
            let old = Array(sample[start..<(start + Int.random(in: 1...10, using: &generator))])
            var new = old
            for _ in 0..<Int.random(in: 0...3, using: &generator) {
                let op = Int.random(in: 0..<3, using: &generator)
                if op == 0, !new.isEmpty {
                    new.remove(at: Int.random(in: 0..<new.count, using: &generator))
                } else if op == 1 {
                    new.insert("inserted \(Int.random(in: 0...9, using: &generator))",
                               at: Int.random(in: 0...new.count, using: &generator))
                } else if !new.isEmpty {
                    let i = Int.random(in: 0..<new.count, using: &generator)
                    new[i] += " // changed"
                }
            }
            let oldText = old.joined(separator: "\n"), newText = new.joined(separator: "\n")
            let rows = LineDiff.rows(old: oldText, new: newText)
            let oldSide = rows.filter { $0.kind != .added }.map { String($0.text) }.joined(separator: "\n")
            let newSide = rows.filter { $0.kind != .removed }.map { String($0.text) }.joined(separator: "\n")
            #expect(oldSide == oldText)
            #expect(newSide == newText)
        }
    }

    @Test func aTrailingNewlineIsKept() {
        let rows = LineDiff.rows(old: "a\nb", new: "a\nb\n")
        let newSide = rows.filter { $0.kind != .removed }.map { String($0.text) }.joined(separator: "\n")
        #expect(newSide == "a\nb\n")
    }

    @Test func eachRowKnowsItsLineOnEachSide() {
        let rows = LineDiff.rows(old: "a\nx\nb", new: "a\ny\nz\nb")
        #expect(rows.map(\.oldIndex) == [0, 1, nil, nil, 2])
        #expect(rows.map(\.newIndex) == [0, nil, 1, 2, 3])
    }

    /// SC-004: a one-word change in a 40-line passage shows at most ten lines by default.
    @Test func aOneWordChangeShowsAtMostTenLines() {
        let old = (1...40).map { "let v\($0) = \($0)" }
        var new = old
        new[19] = "let v20 = 2000"
        let rows = LineDiff.rows(old: old.joined(separator: "\n"), new: new.joined(separator: "\n"))
        let hidden = Folds.of(rows).reduce(0) { $0 + $1.range.count }
        #expect(rows.count - hidden <= 10)
    }

    // MARK: Whole file (US3)

    @Test func wholeFileRowsKeepTheirKindsAndNumbersAndGainWordMarks() {
        let rows = LineDiff.rows(whole: [
            (kind: .context, text: "let a = 1", newLine: 1),
            (kind: .removed, text: "let b = 2", newLine: nil),
            (kind: .added, text: "let b = 3", newLine: 2),
            (kind: .context, text: "let c = 4", newLine: 3),
        ])
        #expect(Self.kinds(rows) == " -+ ")
        #expect(rows.map(\.newLine) == [1, nil, 2, 3])
        #expect(!rows[1].changed.isEmpty)
        #expect(!rows[2].changed.isEmpty)
    }

    @Test func changeStopsAreTheFirstRowOfEachBlock() {
        let rows = LineDiff.rows(old: "a\nb\nc\nd\ne\nf", new: "a\nB\nc\nd\nE\nF")
        #expect(LineDiff.changeStops(rows) == [1, 5])
    }
}

/// A small deterministic generator, so the random edits are the same every run.
struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
