// Drawing only, as `MarkdownBlock` is (037).
#if canImport(Darwin)
import Foundation

extension MarkdownBlock {
    /// Whether the block is only words: a paragraph, a heading, or a list or a quote that
    /// holds nothing else. Words can go in one text view, so a drag selects across them
    /// (#5155); code, a table, a picture and a rule keep views of their own.
    public var isProse: Bool {
        switch self {
        case .paragraph, .heading: true
        case .list(_, _, let items): items.allSatisfy { $0.blocks.allSatisfy(\.isProse) }
        case .quote(let inner): inner.allSatisfy(\.isProse)
        case .code, .table, .image, .rule: false
        }
    }

    /// A message's blocks, in order, as runs of words and the other blocks between them.
    public enum Segment: Hashable, Sendable {
        /// Blocks next to each other that are all prose, drawn as one text.
        case prose(Range<Int>)
        /// One block that is not prose, drawn as before.
        case block(Int)
    }

    /// The blocks, cut where a block that is not prose stands between the words.
    public static func segments(_ blocks: [MarkdownBlock]) -> [Segment] {
        var segments: [Segment] = []
        var start: Int?
        for (index, block) in blocks.enumerated() {
            if block.isProse {
                if start == nil { start = index }
                continue
            }
            if let open = start { segments.append(.prose(open..<index)) }
            start = nil
            segments.append(.block(index))
        }
        if let open = start { segments.append(.prose(open..<blocks.count)) }
        return segments
    }
}
#endif
