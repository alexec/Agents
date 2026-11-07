import Foundation
import Testing
@testable import AgentsKitCore

@Suite("How wide a table's columns are drawn")
struct TableColumnsTests {
    @Test func aTableThatFitsKeepsEachColumn() {
        #expect(TableColumns.widths(natural: [60, 200, 300], room: 600) == [60, 200, 300])
    }

    @Test func aColumnOfSentencesWrapsAndAShortColumnDoesNot() throws {
        // The screenshot in #3943: name, default, purpose; the purpose ran off the right.
        let natural: [Double] = [70, 200, 900]
        let widths = TableColumns.widths(natural: natural, room: 700)
        try #require(widths.count == 3)
        #expect(widths[0] == 70)
        #expect(widths[1] < 200 && widths[1] > TableColumns.floor)
        #expect(widths[2] < 900)
        #expect(abs(widths.reduce(0, +) - 700) < 0.001)
    }

    @Test func noColumnGoesUnderItsLeast() {
        let natural: [Double] = [50, 400, 400]
        for room in stride(from: 0.0, through: 900, by: 10) {
            let widths = TableColumns.widths(natural: natural, room: room)
            for (width, least) in zip(widths, TableColumns.least(natural)) {
                #expect(width >= least - 0.001, "at \(room)pt a column went under its least")
            }
        }
    }

    @Test func aTableTooWideAtItsLeastIsDrawnAtItsLeast() {
        #expect(TableColumns.widths(natural: [300, 300, 300], room: 200) == [160, 160, 160])
    }
}
