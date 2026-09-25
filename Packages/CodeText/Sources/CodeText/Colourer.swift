import Foundation
import SwiftTreeSitter

/// Parses shown text and says what each stretch of it is (041 research R3, R7).
///
/// One actor for the process, so parsing never happens on the main actor and never twice at
/// once for the same text. A document is parsed once, edited in place as its text changes,
/// and asked for spans a window of lines at a time: colouring the first screen of a
/// 5,000-line file is a few milliseconds after the parse (R1).
public actor Colourer {
    public static let shared = Colourer()

    private struct Document {
        let parser: Parser
        var tree: MutableTree
        var text: String
        let query: Query
    }

    private var documents: [UUID: Document] = [:]

    /// Parses `text` as `language` for the document `id`. False when there is nothing to
    /// colour it with: no grammar for the language, or a query that would not compile.
    public func parse(id: UUID, text: String, language: CodeLanguage) async -> Bool {
        guard let grammar = Grammar.language(for: language),
              let query = await Grammar.query(for: language) else { return false }
        let parser = Parser()
        guard (try? parser.setLanguage(grammar)) != nil,
              let tree = parser.parse(text) else { return false }
        documents[id] = Document(parser: parser, tree: tree, text: text, query: query)
        return true
    }

    /// Replaces the document's text, reparsing only around what changed: an agent writing a
    /// file mostly appends, and an append costs a few milliseconds rather than a full parse.
    public func edit(id: UUID, text newText: String) {
        guard var document = documents[id] else { return }
        let old = Array(document.text.utf16)
        let new = Array(newText.utf16)
        var prefix = 0
        while prefix < old.count, prefix < new.count, old[prefix] == new[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < old.count - prefix, suffix < new.count - prefix,
              old[old.count - 1 - suffix] == new[new.count - 1 - suffix] { suffix += 1 }
        let oldEnd = old.count - suffix
        let newEnd = new.count - suffix
        guard prefix != oldEnd || prefix != newEnd else { return }

        document.tree.edit(InputEdit(
            startByte: prefix * 2, oldEndByte: oldEnd * 2, newEndByte: newEnd * 2,
            startPoint: Self.point(at: prefix, in: old),
            oldEndPoint: Self.point(at: oldEnd, in: old),
            newEndPoint: Self.point(at: newEnd, in: new)))
        if let tree = document.parser.parse(tree: document.tree, string: newText) {
            document.tree = tree
        } else if let tree = document.parser.parse(newText) {
            document.tree = tree
        }
        document.text = newText
        documents[id] = document
    }

    /// The spans on each of `lines`, line-relative. `lineStarts[i]` is the UTF-16 offset at
    /// which line `i` starts, with one more entry for the end of the text.
    public func spans(id: UUID, lines: Range<Int>, lineStarts: [Int]) -> [[CodeSpan]] {
        guard let document = documents[id], !lines.isEmpty,
              lines.upperBound < lineStarts.count else {
            return Array(repeating: [], count: lines.count)
        }
        let start = lineStarts[lines.lowerBound]
        let end = lineStarts[lines.upperBound]
        let cursor = document.query.execute(in: document.tree)
        cursor.setRange(NSRange(location: start, length: end - start))
        let named = cursor
            .resolve(with: .init(string: document.text))
            .highlights()

        var result = Array(repeating: [CodeSpan](), count: lines.count)
        // Sorted by where they start, then less specific first, so a later capture over the
        // same text wins: `function.method` over the `function` it also matched. A capture
        // that means plain (`variable`, most often) is never laid down: every grammar
        // matches every identifier as a variable, and letting that win would uncolour the
        // function names and constants matched before it.
        for range in named {
            let role = CodeRole.role(forCapture: range.name)
            guard role != .plain else { continue }
            let r = range.range
            var from = max(r.location, start)
            let to = min(r.location + r.length, end)
            guard from < to else { continue }
            var line = Self.line(containing: from, in: lineStarts, within: lines)
            // A capture across lines (a block comment, a multi-line string) is cut at each
            // line's end, since each line is drawn on its own.
            while from < to, line < lines.upperBound {
                // The line's own text, without the newline after it (the last line has none).
                let isLast = line + 1 == lineStarts.count - 1
                let textEnd = lineStarts[line + 1] - (isLast ? 0 : 1)
                let lineEnd = min(to, textEnd)
                if from < lineEnd {
                    let base = lineStarts[line]
                    Self.lay(CodeSpan(range: (from - base)..<(lineEnd - base), role: role),
                             over: &result[line - lines.lowerBound])
                }
                from = lineStarts[line + 1]
                line += 1
            }
        }
        return result
    }

    /// Lets go of a document no view is showing.
    public func forget(id: UUID) {
        documents[id] = nil
    }

    // MARK: -

    /// The UTF-16 offset each line starts at, and one more for the end of the text: what
    /// `spans(id:lines:lineStarts:)` takes.
    public static func lineStarts(of lines: [Substring]) -> [Int] {
        var starts = [0]
        starts.reserveCapacity(lines.count + 1)
        var offset = 0
        for line in lines {
            offset += line.utf16.count + 1
            starts.append(offset)
        }
        // The last line has no newline after it.
        starts[starts.count - 1] -= 1
        return starts
    }

    /// Puts `span` on top of what the line has, trimming or splitting whatever it covers,
    /// so the line's spans never overlap and the last one laid down wins.
    static func lay(_ span: CodeSpan, over spans: inout [CodeSpan]) {
        var kept: [CodeSpan] = []
        kept.reserveCapacity(spans.count + 2)
        for existing in spans {
            if existing.range.upperBound <= span.range.lowerBound
                || existing.range.lowerBound >= span.range.upperBound {
                kept.append(existing)
                continue
            }
            if existing.range.lowerBound < span.range.lowerBound {
                kept.append(CodeSpan(range: existing.range.lowerBound..<span.range.lowerBound,
                                     role: existing.role))
            }
            if existing.range.upperBound > span.range.upperBound {
                kept.append(CodeSpan(range: span.range.upperBound..<existing.range.upperBound,
                                     role: existing.role))
            }
        }
        kept.append(span)
        kept.sort { $0.range.lowerBound < $1.range.lowerBound }
        spans = kept
    }

    private static func line(containing offset: Int, in starts: [Int], within lines: Range<Int>) -> Int {
        var low = lines.lowerBound, high = lines.upperBound - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if starts[mid] <= offset { low = mid } else { high = mid - 1 }
        }
        return low
    }

    /// A tree-sitter point for a UTF-16 offset: the row, and the column in bytes (two per
    /// UTF-16 unit, as the text is handed over in UTF-16).
    private static func point(at offset: Int, in text: [UInt16]) -> Point {
        var row = 0, lineStart = 0
        for index in 0..<offset where text[index] == 0x0A {
            row += 1
            lineStart = index + 1
        }
        return Point(row: row, column: (offset - lineStart) * 2)
    }
}
