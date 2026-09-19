import Foundation

/// A piece of what an agent said, once the markdown has been read.
///
/// Splitting blocks is a decision and belongs here where it can be exhausted by tests.
/// What each one looks like is the view's business. Inline marks (bold, code spans,
/// links) are left in the text for the renderer, which has a parser for them already.
public enum MarkdownBlock: Hashable, Sendable, Identifiable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bullets([String])
    case numbered([String])
    case quote(String)
    case code(language: String?, text: String)
    case rule

    public var id: String {
        switch self {
        case .heading(let level, let text): return "h\(level):\(text)"
        case .paragraph(let text): return "p:\(text)"
        case .bullets(let items): return "ul:\(items.joined(separator: "\u{1}"))"
        case .numbered(let items): return "ol:\(items.joined(separator: "\u{1}"))"
        case .quote(let text): return "q:\(text)"
        case .code(let language, let text): return "c:\(language ?? ""):\(text)"
        case .rule: return "hr"
        }
    }

    /// Read markdown into blocks.
    ///
    /// Deliberately small. It handles what agents actually send: fenced code, which is
    /// most of it, headings, lists, quotes and paragraphs. Anything it does not know
    /// stays as text rather than disappearing.
    public static func parse(_ markdown: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var bullets: [String] = []
        var numbered: [String] = []
        var quote: [String] = []

        func flushParagraph() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))) }
            paragraph = []
        }
        func flushLists() {
            if !bullets.isEmpty { blocks.append(.bullets(bullets)); bullets = [] }
            if !numbered.isEmpty { blocks.append(.numbered(numbered)); numbered = [] }
            if !quote.isEmpty { blocks.append(.quote(quote.joined(separator: "\n"))); quote = [] }
        }
        func flush() { flushParagraph(); flushLists() }

        var lines = markdown.components(separatedBy: .newlines)[...]
        while let line = lines.first {
            lines = lines.dropFirst()
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                flush()
                let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var body: [String] = []
                while let next = lines.first, !next.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    body.append(next)
                    lines = lines.dropFirst()
                }
                if lines.first != nil { lines = lines.dropFirst() } // the closing fence
                blocks.append(.code(language: language.isEmpty ? nil : language,
                                    text: body.joined(separator: "\n")))
                continue
            }

            if trimmed.isEmpty { flush(); continue }

            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flush()
                blocks.append(.rule)
                continue
            }

            if let hashes = trimmed.firstMatch(ofHashes: ()) {
                flush()
                blocks.append(.heading(level: hashes.level, text: hashes.text))
                continue
            }

            if let item = trimmed.bulletItem {
                flushParagraph()
                if !numbered.isEmpty || !quote.isEmpty { flushLists() }
                bullets.append(item)
                continue
            }

            if let item = trimmed.numberedItem {
                flushParagraph()
                if !bullets.isEmpty || !quote.isEmpty { flushLists() }
                numbered.append(item)
                continue
            }

            if trimmed.hasPrefix(">") {
                flushParagraph()
                if !bullets.isEmpty || !numbered.isEmpty { flushLists() }
                quote.append(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
                continue
            }

            flushLists()
            paragraph.append(line)
        }
        flush()
        return blocks
    }
}

private extension String {
    /// `### Heading` and how deep it is.
    func firstMatch(ofHashes: Void) -> (level: Int, text: String)? {
        let hashes = prefix { $0 == "#" }
        guard (1...6).contains(hashes.count) else { return nil }
        let rest = dropFirst(hashes.count)
        guard rest.first == " " else { return nil }
        return (hashes.count, String(rest).trimmingCharacters(in: .whitespaces))
    }

    var bulletItem: String? {
        for marker in ["- ", "* ", "+ "] where hasPrefix(marker) {
            return String(dropFirst(marker.count))
        }
        return nil
    }

    var numberedItem: String? {
        let digits = prefix { $0.isNumber }
        guard !digits.isEmpty else { return nil }
        let rest = dropFirst(digits.count)
        guard rest.hasPrefix(". ") else { return nil }
        return String(rest.dropFirst(2))
    }
}
