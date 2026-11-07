import Foundation

/// How wide each column of a Markdown table is drawn (#3943).
///
/// A column keeps the width of its widest cell while the table fits. When it does
/// not, the columns wider than `floor` wrap, each in proportion to how much wider
/// than `floor` it is, as a browser's automatic table layout does: a short column
/// (a name, a number) keeps its width and a column of sentences gives up the room.
/// Only when every column is at its least does the table get wider than the room,
/// and scroll. Before this, every column kept its full width, and a column of
/// sentences ran off the right of the reply.
public enum TableColumns {
    /// The least a column that wraps is given, in points: about twelve ems at the
    /// supporting step, so a cell does not wrap to a word a line and a long word
    /// such as `letters+digits+symbols` is not split.
    public static let floor: Double = 160

    /// The least each column may be: its own width, or `floor` when it is wider.
    public static func least(_ natural: [Double]) -> [Double] {
        natural.map { min($0, floor) }
    }

    /// The width of each column, for the columns' natural widths and the room they
    /// share (the room less the spaces between them).
    public static func widths(natural: [Double], room: Double) -> [Double] {
        let least = least(natural)
        let whole = natural.reduce(0, +)
        let lean = least.reduce(0, +)
        if whole <= room { return natural }
        if lean >= room { return least }
        let share = (room - lean) / (whole - lean)
        return zip(least, natural).map { least, natural in least + (natural - least) * share }
    }
}
