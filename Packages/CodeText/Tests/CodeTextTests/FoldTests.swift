@testable import CodeText
import Testing

/// Long unchanged runs folded away (041 FR-010; contract invariant 4).
struct FoldTests {
    /// Rows from a pattern: " " context, "-" removed, "+" added.
    static func rows(_ pattern: String) -> [DiffRow] {
        pattern.map { c in
            DiffRow(kind: c == "-" ? .removed : c == "+" ? .added : .context, text: "x")
        }
    }

    @Test func eightUnchangedLinesAreNotFolded() {
        #expect(Folds.of(Self.rows("+        +")).isEmpty)
    }

    @Test func nineBetweenChangesFoldToThreeFoldThree() {
        let folds = Folds.of(Self.rows("+         +"))
        #expect(folds.map(\.range) == [4..<7])
    }

    @Test func aLeadingRunKeepsThreeBeforeTheFirstChangeOnly() {
        let folds = Folds.of(Self.rows(String(repeating: " ", count: 12) + "-"))
        #expect(folds.map(\.range) == [0..<9])
    }

    @Test func aTrailingRunKeepsThreeAfterTheLastChangeOnly() {
        let folds = Folds.of(Self.rows("+" + String(repeating: " ", count: 12)))
        #expect(folds.map(\.range) == [4..<13])
    }

    @Test func nothingChangedFoldsNothing() {
        #expect(Folds.of(Self.rows(String(repeating: " ", count: 30))).isEmpty)
    }

    @Test func foldsHideOnlyContextAwayFromChanges() {
        let pattern = "  " + String(repeating: " ", count: 20) + "-+" + String(repeating: " ", count: 15)
            + "+" + String(repeating: " ", count: 9) + "-"
        let rows = Self.rows(pattern)
        let changes = rows.indices.filter { rows[$0].kind != .context }
        for fold in Folds.of(rows) {
            for index in fold.range {
                #expect(rows[index].kind == .context)
                #expect(changes.allSatisfy { abs($0 - index) > 3 })
            }
        }
    }
}
