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
    public static func rows(of id: UUID, outcome: [TranscriptItem]) -> [Row] {
        [Row(id: id, pieces: [.head] + outcome.indices.map(Piece.item))]
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
