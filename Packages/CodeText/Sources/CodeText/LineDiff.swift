/// One line of a diff: unchanged, gone or new, and which part of it changed (041 FR-008).
public struct DiffRow: Hashable, Sendable {
    public enum Kind: Hashable, Sendable { case context, removed, added }

    public var kind: Kind
    public var text: Substring
    /// Its number in the file as it now stands, where that is known (Whole file). Edits
    /// carry a passage, not a file, so theirs is nil (FR-013).
    public var newLine: Int?
    /// UTF-16 ranges of the words that changed, against the line it was paired with.
    public var changed: [Range<Int>]
    /// Where it sits in the old text and the new, counted from zero, so a removed line can
    /// be coloured from the old text and an added one from the new.
    public var oldIndex: Int?
    public var newIndex: Int?

    public init(kind: Kind, text: Substring, newLine: Int? = nil, changed: [Range<Int>] = [],
                oldIndex: Int? = nil, newIndex: Int? = nil) {
        self.kind = kind
        self.text = text
        self.newLine = newLine
        self.changed = changed
        self.oldIndex = oldIndex
        self.newIndex = newIndex
    }
}

/// Edits as line diffs, with the changed words marked (041 research R5).
///
/// The standard library's `difference(from:)` does the work: it is Myers' algorithm, on
/// every platform the app runs on, and fast enough for the passages an edit carries.
public enum LineDiff {
    /// The rows of an edit. No old text, or empty old text, is a file being made: every
    /// line added, and nothing to fold or mark.
    /// No new text is a passage deleted: every old line removed, and no empty line added.
    public static func rows(old: String?, new: String) -> [DiffRow] {
        if new.isEmpty, let old, !old.isEmpty {
            return split(old).enumerated().map { DiffRow(kind: .removed, text: $1, oldIndex: $0) }
        }
        let newLines = split(new)
        guard let old, !old.isEmpty else {
            return newLines.enumerated().map { DiffRow(kind: .added, text: $1, newIndex: $0) }
        }
        let oldLines = split(old)
        let difference = newLines.difference(from: oldLines)
        var removed: Set<Int> = [], inserted: Set<Int> = []
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }

        var rows: [DiffRow] = []
        rows.reserveCapacity(oldLines.count + inserted.count)
        var i = 0, j = 0
        while i < oldLines.count || j < newLines.count {
            if i < oldLines.count, removed.contains(i) {
                rows.append(DiffRow(kind: .removed, text: oldLines[i], oldIndex: i))
                i += 1
            } else if j < newLines.count, inserted.contains(j) {
                rows.append(DiffRow(kind: .added, text: newLines[j], newIndex: j))
                j += 1
            } else {
                rows.append(DiffRow(kind: .context, text: newLines[j], oldIndex: i, newIndex: j))
                i += 1
                j += 1
            }
        }
        markWords(&rows)
        return rows
    }

    /// The rows of Whole file, from the lines the daemon worked out (035 `DiffLine`), with
    /// changed words marked the same way.
    public static func rows(whole lines: [(kind: DiffRow.Kind, text: String, newLine: Int?)]) -> [DiffRow] {
        var rows: [DiffRow] = []
        rows.reserveCapacity(lines.count)
        var i = 0, j = 0
        for line in lines {
            var row = DiffRow(kind: line.kind, text: Substring(line.text), newLine: line.newLine)
            if line.kind != .added { row.oldIndex = i; i += 1 }
            if line.kind != .removed { row.newIndex = j; j += 1 }
            rows.append(row)
        }
        markWords(&rows)
        return rows
    }

    /// The first row of each run of changed rows: where Next and Previous go (FR-012).
    public static func changeStops(_ rows: [DiffRow]) -> [Int] {
        rows.indices.filter { index in
            rows[index].kind != .context && (index == 0 || rows[index - 1].kind == .context)
        }
    }

    // MARK: -

    /// Pairs the removed and added rows of each change block, first with first, and marks
    /// the words that differ between each pair.
    static func markWords(_ rows: inout [DiffRow]) {
        var index = 0
        while index < rows.count {
            guard rows[index].kind != .context else { index += 1; continue }
            var end = index
            while end < rows.count, rows[end].kind != .context { end += 1 }
            let removed = (index..<end).filter { rows[$0].kind == .removed }
            let added = (index..<end).filter { rows[$0].kind == .added }
            let pairs = min(removed.count, added.count)
            if pairs <= Limits.wordMarkMaxPairs {
                for k in 0..<pairs {
                    if let marks = WordDiff.marks(old: rows[removed[k]].text, new: rows[added[k]].text) {
                        rows[removed[k]].changed = marks.old
                        rows[added[k]].changed = marks.new
                    }
                }
            }
            index = end
        }
    }

    static func split(_ text: String) -> [Substring] {
        text.split(separator: "\n", omittingEmptySubsequences: false)
    }
}
