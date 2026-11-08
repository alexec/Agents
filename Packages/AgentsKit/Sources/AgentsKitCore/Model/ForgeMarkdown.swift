import Foundation

/// An issue's or a pull request's words, as the forge draws them.
///
/// GitHub's Markdown is not the chat's: it hides HTML comments (every agent's comment
/// starts with `<!-- agent -->`), it draws a few HTML tags (`<details>`, `<summary>`,
/// `<br>`, `<img>`, `<a>`, `<b>`), and it keeps a single line break. `MarkdownBlock`
/// shows raw HTML as it was written, so these are turned into the Markdown that means
/// the same, and any other tag stays text. `forgeMarkdown.ts` does the same on the web
/// page, with the same cases in its test.
public enum ForgeMarkdown {
    /// The url `forge/image` is asked for (#4009, #4010), for an image's source on a forge page: an
    /// https address only, as the daemon reads no other. Nil for anything else, which is drawn as
    /// its alternative text.
    public static func imageURL(of source: String) -> URL? {
        guard let url = URL(string: source.trimmingCharacters(in: .whitespaces)),
              url.scheme?.lowercased() == "https", url.host?.isEmpty == false else { return nil }
        return url
    }

    /// The forge's Markdown as the Markdown `MarkdownText` draws the same.
    public static func markdown(_ source: String) -> String {
        var lines: [String] = []
        var fence: String?
        var comment = false
        let normalised = source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        for raw in normalised.components(separatedBy: "\n") {
            if let open = fence {
                lines.append(raw)
                if closes(raw, open) { fence = nil }
                continue
            }
            if !comment, let opened = fenceOpening(raw) {
                fence = opened
                lines.append(raw)
                continue
            }
            let tableRow = raw.drop(while: \.isWhitespace).hasPrefix("|")
            var text = ""
            for segment in segments(raw) {
                var words = segment.text
                var code = segment.code
                if comment {
                    guard let end = words.range(of: "-->") else { continue }
                    words = String(words[end.upperBound...])
                    code = false
                    comment = false
                }
                if code {
                    text += words
                    continue
                }
                let cut = uncomment(words)
                text += tags(cut.text, tableRow: tableRow)
                comment = cut.open
            }
            // A line that was only a comment or a tag is gone, so it does not end the paragraph it was in.
            if text.trimmingCharacters(in: .whitespaces).isEmpty, !raw.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            lines += text.components(separatedBy: "\n")
        }
        return keepBreaks(lines).joined(separator: "\n")
    }

    /// One piece of a title: its words, or a code span's.
    public struct TitlePart: Hashable, Sendable {
        public var text: String
        public var code: Bool

        public init(text: String, code: Bool) {
            self.text = text
            self.code = code
        }
    }

    /// A title's words and its code spans, the only Markdown a forge draws in a title.
    public static func titleParts(_ title: String) -> [TitlePart] {
        var parts: [TitlePart] = []
        let ns = title as NSString
        var at = 0
        for match in codeSpan.matches(in: title, range: NSRange(location: 0, length: ns.length)) {
            if match.range.location > at {
                parts.append(TitlePart(text: ns.substring(with: NSRange(location: at, length: match.range.location - at)), code: false))
            }
            let ticks = match.range(at: 1).length
            var inner = ns.substring(with: NSRange(location: match.range.location + ticks, length: match.range.length - 2 * ticks))
            // A space at both ends is padding, as CommonMark says, so `` `a` `` can be written.
            if inner.count > 2, inner.hasPrefix(" "), inner.hasSuffix(" "),
               inner.contains(where: { !$0.isWhitespace }) {
                inner = String(inner.dropFirst().dropLast())
            }
            if !inner.isEmpty { parts.append(TitlePart(text: inner, code: true)) }
            at = match.range.location + match.range.length
        }
        if at < ns.length { parts.append(TitlePart(text: ns.substring(from: at), code: false)) }
        return parts
    }

    // MARK: Lines

    private static let codeSpan = regex("(`+)[\\s\\S]*?(?<!`)\\1(?!`)")

    /// The fence a line opens, or nil.
    private static func fenceOpening(_ line: String) -> String? {
        let indent = line.prefix(while: { $0 == " " }).count
        guard indent < 4 else { return nil }
        let rest = line.dropFirst(indent)
        guard let mark = rest.first, mark == "`" || mark == "~" else { return nil }
        let run = rest.prefix(while: { $0 == mark })
        return run.count >= 3 ? String(run) : nil
    }

    private static func closes(_ line: String, _ fence: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix(fence) && trimmed.allSatisfy { $0 == fence.first }
    }

    /// A line cut into its code spans and the words between them.
    private static func segments(_ line: String) -> [(text: String, code: Bool)] {
        let ns = line as NSString
        var parts: [(text: String, code: Bool)] = []
        var at = 0
        for match in codeSpan.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
            parts.append((ns.substring(with: NSRange(location: at, length: match.range.location - at)), false))
            parts.append((ns.substring(with: match.range), true))
            at = match.range.location + match.range.length
        }
        parts.append((ns.substring(from: at), false))
        return parts
    }

    /// Text with its comments taken out; `open` when one runs on past the end.
    private static func uncomment(_ text: String) -> (text: String, open: Bool) {
        var out = ""
        var rest = text[...]
        while let start = rest.range(of: "<!--") {
            out += rest[..<start.lowerBound]
            guard let end = rest[start.upperBound...].range(of: "-->") else { return (out, true) }
            rest = rest[end.upperBound...]
        }
        return (out + rest, false)
    }

    // MARK: Tags

    private static let dropped = "details|p|div|span|sub|sup|u|ins|center|picture|source|small|big|font|tt|abbr|mark|cite|dfn|var|section|article|header|footer|figure|figcaption|nobr|a"

    private static let heading = regex("^\\s*<h([1-6])(?:\\s[^>]*)?>(.*?)</h\\1>\\s*$")
    private static let rule = regex("^\\s*<hr\\s*/?>\\s*$")
    private static let lineBreak = regex("<br\\s*/?>")
    private static let image = regex("<img\\b([^>]*)>")
    private static let anchor = regex("<a\\b([^>]*)>(.*?)</a>")
    private static let summary = regex("<summary(?:\\s[^>]*)?>(.*?)</summary>")
    private static let simple: [(NSRegularExpression, String)] = [
        (regex("</?summary(?:\\s[^>]*)?>"), ""),
        (regex("</?(?:b|strong)>"), "**"),
        (regex("</?(?:i|em)>"), "*"),
        (regex("</?(?:s|del|strike)>"), "~~"),
        (regex("</?(?:code|kbd|samp)>"), "`"),
        (regex("</?(?:\(dropped))(?:\\s[^>]*)?/?>"), ""),
    ]

    /// The HTML GitHub draws, as Markdown; any other tag is left as it was written, and is drawn as text.
    private static func tags(_ text: String, tableRow: Bool) -> String {
        guard text.contains("<") else { return text }
        var text = replace(heading, in: text) { groups in
            "\(String(repeating: "#", count: Int(groups[1]) ?? 1)) \(groups[2].trimmingCharacters(in: .whitespaces))"
        }
        text = replace(rule, in: text) { _ in "---" }
        text = replace(lineBreak, in: text) { _ in tableRow ? " " : "  \n" }
        text = replace(image, in: text) { groups in
            guard let source = attribute(groups[1], "src") else { return "" }
            let alt = (attribute(groups[1], "alt") ?? "").replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
            return "![\(alt)](<\(source)>)"
        }
        text = replace(anchor, in: text) { groups in
            attribute(groups[1], "href").map { "[\(groups[2])](<\($0)>)" } ?? groups[2]
        }
        text = replace(summary, in: text) { groups in
            let words = groups[1].trimmingCharacters(in: .whitespaces)
            return words.isEmpty ? "" : "**\(words)**"
        }
        for (pattern, mark) in simple {
            text = replace(pattern, in: text) { _ in mark }
        }
        return text
    }

    /// An attribute's value, quoted or not.
    private static func attribute(_ attributes: String, _ name: String) -> String? {
        let pattern = regex("\\b\(name)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s>]+))")
        let ns = attributes as NSString
        guard let match = pattern.firstMatch(in: attributes, range: NSRange(location: 0, length: ns.length)) else { return nil }
        for group in 1...3 where match.range(at: group).location != NSNotFound {
            return ns.substring(with: match.range(at: group))
        }
        return nil
    }

    // MARK: Line breaks

    private static let notPlain = regex("^(?: {4}|\\t)|^\\s*(?:#{1,6}(?:\\s|$)|>|\\||[-+*](?:\\s|$)|\\d{1,9}[.)](?:\\s|$)|`{3}|~{3}|<)")
    private static let underline = regex("^\\s*\\|?[\\s|:=-]*[=-][\\s|:=-]*$")

    /// A line of a paragraph followed by another ends in a hard break, as the forge draws it.
    private static func keepBreaks(_ lines: [String]) -> [String] {
        var fence: String?
        return lines.enumerated().map { index, line in
            if let open = fence {
                if closes(line, open) { fence = nil }
                return line
            }
            if let opened = fenceOpening(line) {
                fence = opened
                return line
            }
            guard index + 1 < lines.count else { return line }
            let next = lines[index + 1]
            guard plain(line), plain(next), !matches(underline, next) else { return line }
            if line.hasSuffix("  ") || line.hasSuffix("\\") { return line }
            return line + "  "
        }
    }

    private static func plain(_ line: String) -> Bool {
        !line.trimmingCharacters(in: .whitespaces).isEmpty && !matches(notPlain, line)
    }

    // MARK: Expressions

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    private static func matches(_ pattern: NSRegularExpression, _ text: String) -> Bool {
        pattern.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }

    /// Every match replaced by what `with` makes of its groups (an absent group is empty).
    private static func replace(_ pattern: NSRegularExpression, in text: String, with: ([String]) -> String) -> String {
        let ns = text as NSString
        var out = ""
        var at = 0
        for match in pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: at, length: match.range.location - at))
            let groups = (0..<match.numberOfRanges).map { group in
                match.range(at: group).location == NSNotFound ? "" : ns.substring(with: match.range(at: group))
            }
            out += with(groups)
            at = match.range.location + match.range.length
        }
        return out + ns.substring(from: at)
    }
}
