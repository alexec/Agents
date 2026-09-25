/// Where colour and word marks stop being worth what they cost (041 FR-018, research R6).
///
/// In one place, so the reason line a view shows and the tests that prove it agree.
public enum Limits {
    /// Text longer than this (UTF-16 units) is shown plain. The files pane reads the first
    /// 128 KB of a file already; this leaves room for pages and diffs.
    public static let colourMaxUTF16 = 512 * 1024
    /// A single line longer than this makes the whole text plain. Measured (R1): one 294 KB
    /// minified line took 734 ms even for one screen, because a screen cannot split a line.
    public static let colourMaxLine = 4_000
    /// Word marks are skipped on a line longer than this: token diffs are quadratic at worst.
    public static let wordMarkMaxLine = 1_000
    /// Word marks are skipped in a change block of more pairs than this: it is a rewrite.
    public static let wordMarkMaxPairs = 200
    /// An unchanged run longer than this is folded…
    public static let foldMinimum = 8
    /// …keeping this many lines beside each change, as `git diff -U3` does.
    public static let foldContext = 3
    /// Spans are asked for this many lines at a time.
    public static let window = 200

    /// Why a text is shown without colour, or nil when it is not.
    public static func plainReason(for text: String) -> PlainReason? {
        let utf16 = text.utf16
        if utf16.count > colourMaxUTF16 { return .tooLarge }
        var run = 0
        for unit in utf16 {
            if unit == 0x0A {
                run = 0
            } else {
                run += 1
                if run > colourMaxLine { return .lineTooLong }
            }
        }
        return nil
    }
}

/// Why code is shown without colour. Said on screen, not left as a mystery (FR-018).
public enum PlainReason: Hashable, Sendable {
    case tooLarge, lineTooLong

    public var message: String {
        switch self {
        case .tooLarge: "Shown without colour: the file is too large."
        case .lineTooLong: "Shown without colour: a line is too long."
        }
    }
}

/// A stretch of one line and what it is. Ranges are UTF-16 offsets within the line, which
/// is what `AttributedString` and `NSString` both index by.
public struct CodeSpan: Hashable, Sendable {
    public var range: Range<Int>
    public var role: CodeRole

    public init(range: Range<Int>, role: CodeRole) {
        self.range = range
        self.role = role
    }
}
