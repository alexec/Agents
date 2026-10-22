import Foundation

/// Where each row of a chat's transcript goes, and which rows are drawn (#2310).
///
/// The transcript draws a window of its rows: those on screen and a pane either side. It
/// knows every row's height, measured once it was drawn or estimated until then, so the
/// height of the whole is a sum it made, never a lazy stack's guess. A row's place comes
/// from these heights alone.
///
/// Reading back, one row is the anchor: it stays where it is in the content, and the rows
/// above it are placed upward from it. A row above that changes height (an earlier page,
/// steps that came, a row measured for the first time) moves the rows above it, and the
/// space left at the top of the content, the slack, takes the difference. Nothing on
/// screen moves, and the pane's offset is not touched. Only when the slack runs out does
/// the pane move, once, by `shift`.
///
/// Following the end, there is no anchor: the rows go down from the slack, and the scroll
/// view holds the foot.
public enum TranscriptPlacement {
    /// The rows placed: where each starts, the content's height, and the slack.
    public struct Placed: Equatable, Sendable {
        /// Where each row starts in the content, top first.
        public var tops: [Double]
        /// The empty space above the first row.
        public var slack: Double
        /// How far everything moved down because the slack ran out: the pane moves by as
        /// much, so nothing on screen moves. Zero almost always.
        public var shift: Double
        /// The content's height: the slack and every row.
        public var height: Double
    }

    /// Places rows of `heights`. With an `anchor` (a row's index, and where it starts), that
    /// row stays where it is, and the slack is what is left above the first row; when that
    /// would be less than nothing, everything moves down to leave `reserve`. With no
    /// anchor, the rows go down from `slack`.
    public static func place(heights: [Double], slack: Double, anchor: (index: Int, top: Double)?,
                             reserve: Double) -> Placed {
        var tops = [Double](repeating: 0, count: heights.count)
        guard !heights.isEmpty else { return Placed(tops: [], slack: slack, shift: 0, height: slack) }
        if let anchor, heights.indices.contains(anchor.index) {
            tops[anchor.index] = anchor.top
            var y = anchor.top
            for i in stride(from: anchor.index - 1, through: 0, by: -1) {
                y -= heights[i]
                tops[i] = y
            }
            y = anchor.top
            for i in anchor.index..<heights.count {
                tops[i] = y
                y += heights[i]
            }
        } else {
            var y = slack
            for i in heights.indices {
                tops[i] = y
                y += heights[i]
            }
        }
        var shift = 0.0
        if tops[0] < 0 {
            shift = -tops[0] + reserve
            for i in tops.indices { tops[i] += shift }
        }
        let height = tops[tops.count - 1] + heights[heights.count - 1]
        return Placed(tops: tops, slack: tops[0], shift: shift, height: height)
    }

    /// The rows to draw: those that meet `from..<to` in the content, given where they start
    /// and how tall they are. Empty when none does.
    public static func window(tops: [Double], heights: [Double], from: Double, to: Double) -> Range<Int> {
        guard tops.count == heights.count, !tops.isEmpty else { return 0..<0 }
        // The first row that ends below `from`.
        var low = 0, high = tops.count
        while low < high {
            let mid = (low + high) / 2
            if tops[mid] + heights[mid] <= from { low = mid + 1 } else { high = mid }
        }
        var end = low
        while end < tops.count, tops[end] < to { end += 1 }
        return low..<max(low, end)
    }

    /// The row a reader's place is held by: the first that starts on screen, or the one the
    /// top of the screen is in when none does. Nil with no rows on screen.
    public static func anchor(tops: [Double], heights: [Double], visibleTop: Double,
                              visibleBottom: Double) -> (index: Int, top: Double)? {
        let shown = window(tops: tops, heights: heights, from: visibleTop, to: visibleBottom)
        guard let first = shown.first else { return nil }
        if let starting = shown.first(where: { tops[$0] >= visibleTop - 0.5 }) {
            return (starting, tops[starting])
        }
        return (first, tops[first])
    }
}
