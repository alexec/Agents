import Foundation

/// The subset of YAML a workflow's metadata is allowed to use.
///
/// Not a YAML implementation, and deliberately not trying to be one. A workflow's
/// metadata is a handful of keys, block sequences and inline lists — the shapes in
/// `contracts/workflow-file.md` and nothing else. Anything outside that throws, and the
/// workflow is listed as unreadable with the reason, because a workflow that runs
/// something other than what its author wrote would be worse than one that does not run.
///
/// The alternative was a YAML dependency. This package has none outside its tests, the
/// daemon ships as one signed binary, and a few hundred lines that only ever say no is
/// cheaper than a parser that accepts anchors, aliases and multi-document streams that
/// no workflow will ever contain.
enum YAMLNode: Equatable {
    case scalar(String)
    case sequence([YAMLNode])
    case mapping([String: YAMLNode])

    struct Failure: Error {
        var message: String
        init(_ message: String) { self.message = message }
    }

    var scalar: String? {
        if case .scalar(let value) = self { return value }
        return nil
    }

    /// The strings in a sequence, whether it was written inline or as a block. A lone
    /// scalar reads as a sequence of one, because `days: mon` and `days: [mon]` mean
    /// the same thing to anyone writing them.
    var sequenceValues: [String]? {
        switch self {
        case .sequence(let items): return items.compactMap(\.scalar)
        case .scalar(let value): return value.isEmpty ? [] : [value]
        case .mapping: return nil
        }
    }

    /// The same tree as `JSONValue`, for the unknown keys that are kept and never read.
    var jsonValue: JSONValue {
        switch self {
        case .scalar(let value): return .string(value)
        case .sequence(let items): return .array(items.map(\.jsonValue))
        case .mapping(let pairs): return .object(pairs.mapValues(\.jsonValue))
        }
    }

    // MARK: Parsing

    /// The top level of a metadata block, which is always a mapping.
    static func mapping(from lines: [String]) throws -> [String: YAMLNode] {
        var reader = Reader(lines: lines.enumerated().compactMap(Line.init))
        let node = try reader.readBlock(indentedBy: 0)
        guard case .mapping(let pairs) = node else {
            guard case .scalar(let value) = node, value.isEmpty else {
                throw Failure("The metadata is not a list of keys")
            }
            return [:]
        }
        return pairs
    }

    /// One significant line: what it says, and how far in it starts.
    private struct Line {
        var indent: Int
        var text: String
        var number: Int

        init?(_ pair: (offset: Int, element: String)) {
            let raw = pair.element
            // Comments and blank lines carry nothing and are dropped before the parser
            // has to think about them. A `#` inside quotes is not a comment, which is
            // the one case this has to be careful about.
            let withoutComment = Self.stripComment(raw)
            let trimmed = withoutComment.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }
            indent = withoutComment.prefix { $0 == " " }.count
            text = trimmed
            number = pair.offset + 2 // +1 for zero-based, +1 for the opening `---`
        }

        static func stripComment(_ line: String) -> String {
            var inQuote: Character?
            var result = ""
            for (index, character) in line.enumerated() {
                if let quote = inQuote {
                    if character == quote { inQuote = nil }
                } else if character == "\"" || character == "'" {
                    inQuote = character
                } else if character == "#" {
                    // A `#` mid-word is part of it; only one starting a token comments.
                    let previous = index == 0 ? " " : Array(line)[index - 1]
                    if previous == " " || index == 0 { break }
                }
                result.append(character)
            }
            return result
        }
    }

    private struct Reader {
        var lines: [Line]
        var index = 0

        var current: Line? { index < lines.count ? lines[index] : nil }

        /// Everything at `indent` or deeper, as one node.
        mutating func readBlock(indentedBy indent: Int) throws -> YAMLNode {
            guard let first = current, first.indent >= indent else { return .scalar("") }
            return first.text.hasPrefix("- ") || first.text == "-"
                ? .sequence(try readSequence(indentedBy: first.indent))
                : .mapping(try readMapping(indentedBy: first.indent))
        }

        mutating func readSequence(indentedBy indent: Int) throws -> [YAMLNode] {
            var items: [YAMLNode] = []
            while let line = current, line.indent == indent,
                  line.text.hasPrefix("- ") || line.text == "-" {
                index += 1
                let entry = line.text == "-" ? "" : String(line.text.dropFirst(2))
                    .trimmingCharacters(in: .whitespaces)
                if entry.isEmpty {
                    items.append(try readBlock(indentedBy: indent + 1))
                } else if let (key, value) = Self.split(entry) {
                    // `- schedule:` and its settings, which are indented past the dash.
                    var pairs: [String: YAMLNode] = [:]
                    if value.isEmpty {
                        pairs[key] = try readBlock(indentedBy: indent + 1)
                    } else {
                        pairs[key] = try Self.inline(value, at: line.number)
                    }
                    items.append(.mapping(pairs))
                } else {
                    items.append(try Self.inline(entry, at: line.number))
                }
            }
            return items
        }

        mutating func readMapping(indentedBy indent: Int) throws -> [String: YAMLNode] {
            var pairs: [String: YAMLNode] = [:]
            while let line = current, line.indent == indent {
                guard !line.text.hasPrefix("- ") else { break }
                guard let (key, value) = Self.split(line.text) else {
                    throw Failure("Line \(line.number): \"\(line.text)\" is not a key")
                }
                index += 1
                if value.isEmpty {
                    pairs[key] = try readBlock(indentedBy: indent + 1)
                } else {
                    pairs[key] = try Self.inline(value, at: line.number)
                }
            }
            return pairs
        }

        /// `key: value`, or nil when the line is not one.
        static func split(_ text: String) -> (String, String)? {
            // A colon inside quotes belongs to the value: `at: ":00"` is one key.
            var inQuote: Character?
            for (offset, character) in text.enumerated() {
                if let quote = inQuote {
                    if character == quote { inQuote = nil }
                    continue
                }
                if character == "\"" || character == "'" { inQuote = character; continue }
                guard character == ":" else { continue }
                let after = text.index(text.startIndex, offsetBy: offset + 1)
                // `09:00` is not a key and a value. A colon only separates when what
                // follows it is a space or the end of the line.
                guard after == text.endIndex || text[after] == " " else { continue }
                let key = String(text.prefix(offset)).trimmingCharacters(in: .whitespaces)
                let value = String(text[after...]).trimmingCharacters(in: .whitespaces)
                guard !key.isEmpty else { return nil }
                return (key, value)
            }
            return nil
        }

        /// A value written on one line: a scalar, or an inline `[a, b]` sequence.
        static func inline(_ text: String, at line: Int) throws -> YAMLNode {
            guard text.hasPrefix("[") else { return .scalar(unquote(text)) }
            guard text.hasSuffix("]") else {
                throw Failure("Line \(line): \"\(text)\" opens a list and never closes it")
            }
            let inner = String(text.dropFirst().dropLast())
            guard !inner.trimmingCharacters(in: .whitespaces).isEmpty else { return .sequence([]) }
            return .sequence(splitInline(inner).map { .scalar(unquote($0)) })
        }

        /// Commas, except the ones inside quotes.
        static func splitInline(_ text: String) -> [String] {
            var parts: [String] = []
            var currentPart = ""
            var inQuote: Character?
            for character in text {
                if let quote = inQuote {
                    if character == quote { inQuote = nil }
                    currentPart.append(character)
                } else if character == "\"" || character == "'" {
                    inQuote = character
                    currentPart.append(character)
                } else if character == "," {
                    parts.append(currentPart.trimmingCharacters(in: .whitespaces))
                    currentPart = ""
                } else {
                    currentPart.append(character)
                }
            }
            let last = currentPart.trimmingCharacters(in: .whitespaces)
            if !last.isEmpty { parts.append(last) }
            return parts
        }

        static func unquote(_ text: String) -> String {
            guard text.count >= 2, let first = text.first, let last = text.last,
                  first == last, first == "\"" || first == "'" else { return text }
            return String(text.dropFirst().dropLast())
        }
    }
}
