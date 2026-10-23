import Foundation
import Testing
@testable import AgentsKitCore

/// A long reply is drawn as rows of a few blocks, not as one row laid out whole
/// (P20261022-18).
struct TurnRowsTests {
    /// 1,000 paragraphs and 20 fenced code blocks.
    private static let longReply: String = (0..<1_000).map { index in
        let paragraph = "Paragraph \(index) of the reply."
        return index % 50 == 0 ? paragraph + "\n\n```swift\nlet line = \(index)\n```" : paragraph
    }
    .joined(separator: "\n\n")

    private func said(_ text: String) -> TranscriptItem {
        .entry(TranscriptEntry(kind: .agentMessage(messageID: nil, text: text)))
    }

    private func blocks(in row: TurnRows.Row) -> Int {
        row.pieces.reduce(0) { sum, piece in
            if case .blocks(_, let range) = piece { return sum + range.count }
            return sum
        }
    }

    /// The cost: the blocks a drawn row lays out are bounded by `size`, not by the reply.
    @Test func aLongReplyIsRowsOfAFewBlocks() throws {
        let count = try #require(TurnRows.blockCount(said(Self.longReply)))
        #expect(count == 1_020)
        let turn = UUID()
        let rows = TurnRows.rows(of: turn, outcome: [said(Self.longReply)])
        #expect(rows.count == (count + TurnRows.size - 1) / TurnRows.size)
        for row in rows { #expect(blocks(in: row) <= TurnRows.size) }
        // Every block once, in order.
        let ranges = rows.flatMap(\.pieces).compactMap { piece -> Range<Int>? in
            if case .blocks(0, let range) = piece { return range }
            return nil
        }
        #expect(ranges.first?.lowerBound == 0)
        #expect(ranges.last?.upperBound == count)
        #expect(zip(ranges, ranges.dropFirst()).allSatisfy { $0.upperBound == $1.lowerBound })
    }

    /// The first row is the turn's, with the ask and steps; the ids are steady and apart.
    @Test func theFirstRowIsTheTurns() {
        let turn = UUID()
        let outcome = [said(Self.longReply), said("Done.")]
        let rows = TurnRows.rows(of: turn, outcome: outcome)
        #expect(rows.first?.id == turn)
        #expect(rows.first?.pieces.first == .head)
        #expect(rows.dropFirst().allSatisfy { !$0.pieces.contains(.head) })
        #expect(Set(rows.map(\.id)).count == rows.count)
        #expect(TurnRows.rows(of: turn, outcome: outcome).map(\.id) == rows.map(\.id))
        // What follows the long reply ends its last row.
        #expect(rows.last?.pieces.last == .item(1))
    }

    /// A reply of no more than `size` blocks, and anything that is not a reply, stay whole:
    /// a turn of them is one row, as it was.
    @Test func aShortTurnIsOneRow() {
        let short = (0..<TurnRows.size).map { "Paragraph \($0)." }.joined(separator: "\n\n")
        let turn = UUID()
        let rows = TurnRows.rows(of: turn, outcome: [said(short), said("Done.")])
        #expect(rows == [TurnRows.Row(id: turn, pieces: [.head, .item(0), .item(1)])])
    }

    /// While a reply streams, the rows already there keep their ids: only the last changes.
    @Test func aGrowingReplyKeepsItsRows() {
        let turn = UUID()
        let half = Self.longReply.components(separatedBy: "\n\n").prefix(500).joined(separator: "\n\n")
        let before = TurnRows.rows(of: turn, outcome: [said(half)])
        let after = TurnRows.rows(of: turn, outcome: [said(Self.longReply)])
        #expect(Array(after.prefix(before.count - 1)) == Array(before.dropLast()))
    }
}
