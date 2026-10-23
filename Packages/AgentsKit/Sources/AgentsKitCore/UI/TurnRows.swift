import Foundation

/// The rows of the chat's transcript that one turn is drawn as (P20261022-18).
///
/// The transcript lays out and draws whole rows, measured, never estimated, where they are
/// on screen (#2310). A turn is one row, so a reply of a thousand paragraphs was laid out
/// whole each time its turn was drawn. A long reply is cut into rows of `size` blocks: only
/// those near the screen are drawn, and each is still measured whole.
public enum TurnRows {
    /// The most blocks of a reply in one row, and the most a reply has before it is cut.
    public static let size = 24

    /// What a row draws, in order.
    public enum Piece: Hashable, Sendable {
        /// The ask and the steps: what comes before the outcome. Only in the turn's first row.
        case head
        /// An item of the outcome, whole, by its index.
        case item(Int)
        /// Some of the blocks of an outcome item's text, by the item's index.
        case blocks(item: Int, Range<Int>)
    }

    /// One row: the turn's first has the turn's id.
    public struct Row: Hashable, Sendable, Identifiable {
        public var id: UUID
        public var pieces: [Piece]
    }

    /// The rows of the turn `id` whose drawn outcome is `outcome`.
    /// A reply of more than `size` blocks is cut every `size` blocks; a new row starts at
    /// each cut, and what follows the reply ends the row its last blocks are in.
    public static func rows(of id: UUID, outcome: [TranscriptItem]) -> [Row] {
        var rows = [Row(id: id, pieces: [.head])]
        for (index, item) in outcome.enumerated() {
            guard let count = blockCount(item), count > size else {
                rows[rows.count - 1].pieces.append(.item(index))
                continue
            }
            for start in stride(from: 0, to: count, by: size) {
                let piece = Piece.blocks(item: index, start..<min(start + size, count))
                if start == 0 {
                    rows[rows.count - 1].pieces.append(piece)
                } else {
                    rows.append(Row(id: rowID(id, rows.count), pieces: [piece]))
                }
            }
        }
        return rows
    }

    /// The id of a turn's row after its first: the turn's id with its last four bytes
    /// turned over by the row's place, so it is the same on every pass. Also what the blocks
    /// of a reply that a row goes on with are drawn by: the reply's id and where they start.
    public static func rowID(_ turn: UUID, _ row: Int) -> UUID {
        var bytes = turn.uuid
        let at = UInt32(truncatingIfNeeded: row)
        bytes.12 ^= UInt8(truncatingIfNeeded: at >> 24)
        bytes.13 ^= UInt8(truncatingIfNeeded: at >> 16)
        bytes.14 ^= UInt8(truncatingIfNeeded: at >> 8)
        bytes.15 ^= UInt8(truncatingIfNeeded: at)
        return UUID(uuid: bytes)
    }

    /// How many blocks an item's text is, when it is a reply that is one text: nil otherwise.
    public static func blockCount(_ item: TranscriptItem) -> Int? {
        text(of: item).map { MarkdownBlock.parsed($0).count }
    }

    /// The text of a reply that is one text, which is what can be cut into rows.
    public static func text(of item: TranscriptItem) -> String? {
        guard case .entry(let entry) = item, case .agentMessage(_, let text, let blocks) = entry.kind else { return nil }
        if blocks.isEmpty { return text }
        guard blocks.count == 1, case .text(let only) = blocks[0] else { return nil }
        return only
    }
}
