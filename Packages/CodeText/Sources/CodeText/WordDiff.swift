/// Which words of a changed line changed (041 FR-009, research R5).
enum WordDiff {
    /// The changed ranges on each side, or nil when the lines have too little in common to
    /// be one line edited (a rewrite, marked as a whole by its line), or are too long to
    /// compare quickly.
    static func marks(old: Substring, new: Substring) -> (old: [Range<Int>], new: [Range<Int>])? {
        guard old.utf16.count <= Limits.wordMarkMaxLine,
              new.utf16.count <= Limits.wordMarkMaxLine else { return nil }
        let a = tokens(old), b = tokens(new)
        let difference = b.map(\.text).difference(from: a.map(\.text))
        let shared = a.count - difference.removals.count
        guard shared * 3 >= max(a.count, b.count) else { return nil }

        var oldRanges: [Range<Int>] = [], newRanges: [Range<Int>] = []
        for change in difference {
            switch change {
            case .remove(let offset, _, _): oldRanges.append(a[offset].range)
            case .insert(let offset, _, _): newRanges.append(b[offset].range)
            }
        }
        return (merged(oldRanges), merged(newRanges))
    }

    struct Token {
        var text: Substring
        var range: Range<Int>
    }

    /// A line in words: runs of letters, digits and underscores; runs of whitespace; and
    /// every other character on its own.
    static func tokens(_ line: Substring) -> [Token] {
        enum Class { case word, space, other }
        func kind(_ c: Character) -> Class {
            if c.isLetter || c.isNumber || c == "_" { return .word }
            if c.isWhitespace { return .space }
            return .other
        }
        var result: [Token] = []
        var start = line.startIndex, startOffset = 0, offset = 0
        var current: Class?
        for index in line.indices {
            let c = line[index]
            let k = kind(c)
            if let current, current != k || k == .other {
                result.append(Token(text: line[start..<index], range: startOffset..<offset))
                start = index
                startOffset = offset
            }
            current = k
            offset += c.utf16.count
        }
        if current != nil {
            result.append(Token(text: line[start...], range: startOffset..<offset))
        }
        return result
    }

    /// Neighbouring tokens that both changed read as one change: `foo(bar` not `foo`,`(`,`bar`.
    private static func merged(_ ranges: [Range<Int>]) -> [Range<Int>] {
        var result: [Range<Int>] = []
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = result.last, last.upperBound >= range.lowerBound {
                result[result.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                result.append(range)
            }
        }
        return result
    }
}
