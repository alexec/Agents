/// A run of unchanged lines, hidden behind one line that says how many (041 FR-010).
public struct Fold: Hashable, Sendable {
    /// The rows it hides.
    public var range: Range<Int>

    public init(range: Range<Int>) {
        self.range = range
    }
}

public enum Folds {
    /// A fold for every unchanged run longer than `minimum`, leaving `context` lines showing
    /// beside each change it touches, as `git diff -U3` does. Nothing changed, nothing folded.
    public static func of(_ rows: [DiffRow], context: Int = Limits.foldContext,
                          minimum: Int = Limits.foldMinimum) -> [Fold] {
        guard rows.contains(where: { $0.kind != .context }) else { return [] }
        var folds: [Fold] = []
        var index = 0
        while index < rows.count {
            guard rows[index].kind == .context else { index += 1; continue }
            var end = index
            while end < rows.count, rows[end].kind == .context { end += 1 }
            if end - index > minimum {
                let from = index + (index > 0 ? context : 0)
                let to = end - (end < rows.count ? context : 0)
                if from < to { folds.append(Fold(range: from..<to)) }
            }
            index = end
        }
        return folds
    }
}
