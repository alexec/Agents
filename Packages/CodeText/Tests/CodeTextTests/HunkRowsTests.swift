@testable import CodeText
import Testing

/// A file's change as numbered rows, with breaks between hunks and rows side by side (#1472).
struct HunkRowsTests {
    @Test func aHunkNumbersBothSides() {
        let rows = LineDiff.rows(hunks: [.init(lines: [(.context, "a"), (.removed, "b"), (.added, "B"), (.context, "c")])])
        #expect(rows.map(\.oldLine) == [1, 2, nil, 3])
        #expect(rows.map(\.newLine) == [1, nil, 2, 3])
        #expect(rows.map(\.oldIndex) == [0, 1, nil, 2])
        #expect(rows.map(\.newIndex) == [0, nil, 1, 2])
        #expect(LineDiff.breaks(rows).isEmpty)
    }

    @Test func aSecondHunkFurtherOnStartsABreak() {
        let rows = LineDiff.rows(hunks: [
            .init(oldStart: 1, newStart: 1, lines: [(.context, "a"), (.added, "x")]),
            .init(oldStart: 40, newStart: 41, lines: [(.removed, "y"), (.context, "z")]),
        ])
        #expect(rows.map(\.oldLine) == [1, nil, 40, 41])
        #expect(rows.map(\.newLine) == [1, 2, nil, 41])
        #expect(LineDiff.breaks(rows) == [2])
    }

    @Test func aFirstHunkPastLineOneStartsABreak() {
        let rows = LineDiff.rows(hunks: [.init(oldStart: 10, newStart: 10, lines: [(.context, "a")])])
        #expect(LineDiff.breaks(rows) == [0])
    }

    @Test func sideBySidePairsRemovedWithAdded() {
        let rows = LineDiff.rows(hunks: [.init(lines: [
            (.context, "a"), (.removed, "b"), (.removed, "c"), (.added, "B"), (.context, "d"), (.added, "e"),
        ])])
        let pairs = LineDiff.sideBySide(Array(rows.indices), in: rows)
        #expect(pairs.map(\.old) == [0, 1, 2, 4, nil])
        #expect(pairs.map(\.new) == [0, 3, nil, 4, 5])
    }
}
