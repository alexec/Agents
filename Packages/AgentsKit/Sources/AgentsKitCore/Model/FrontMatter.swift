import Foundation

/// The metadata block some markdown files open with, and why it has to go.
///
/// CommonMark has never heard of YAML front matter. Handed a file that opens with
/// `---`, the parser reads the opening marker as a thematic break, the keys as a setext
/// heading — and then swallows the document's real first heading into that same
/// heading. Content is lost, not merely mis-styled. 224 files in this repository open
/// this way.
///
/// The rule is positional, and that is the whole care of it: `---` on the first line is
/// a fence around metadata, and `---` anywhere else is a horizontal rule that the
/// reader is entitled to see. Getting that backwards eats the top of a document.
public enum FrontMatter {
    /// The document without its opening metadata block.
    ///
    /// Returns the source unchanged unless the very first line is `---` and a closing
    /// `---` follows it. A file that opens with a rule and never closes one is a file
    /// with a rule in it.
    public static func strip(_ source: String) -> String {
        var lines = source.components(separatedBy: "\n")[...]
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return source }
        lines = lines.dropFirst()

        guard let closing = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == "---"
        }) else { return source }

        lines = lines[lines.index(after: closing)...]
        // The blank line the block is usually followed by belongs to the block, not to
        // the document under it.
        while lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            lines = lines.dropFirst()
        }
        return lines.joined(separator: "\n")
    }
}

/// Changing one key in the metadata block of a file somebody else wrote.
///
/// Here rather than in a file of its own, because the positional rule about `---` is
/// `FrontMatter`'s and stating it a second time somewhere else is how the top of a
/// document gets eaten. `strip` and this read the same fence the same way.
///
/// This is the only thing in the app that writes into a file a person wrote. It is
/// theirs: it is in their repository, it goes into their history, and somebody will
/// read the diff. So it does one key at a time and refuses anything it cannot do
/// exactly, rather than doing its best — a best effort here does not fail loudly, it
/// succeeds quietly and leaves a change nobody asked for in somebody's commit.
public enum FrontMatterEdit {
    /// Why nothing was written. Carries a sentence a person can act on, because the
    /// app is going to show it to them rather than keep the change and pretend.
    public struct Refusal: Error, Sendable {
        public var message: String
        public init(_ message: String) { self.message = message }
    }

    /// Set, change or remove one top-level scalar key. `nil` removes it.
    ///
    /// Pure: a function of text returning text. The atomic write and the rescan that
    /// follows belong with every other workflow write, not here.
    public static func set(_ key: String, to value: String?, in source: String) throws -> String {
        let newline = source.range(of: "\r\n") != nil ? "\r\n" : "\n"
        var lines = source.components(separatedBy: newline)

        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else {
            throw Refusal("This file does not start with a metadata block, and one cannot be invented for it")
        }
        guard let closing = lines.dropFirst().firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == "---"
        }) else {
            throw Refusal("The metadata block is never closed")
        }

        // Column zero, and nothing else. A `model:` indented under a trigger belongs to
        // the trigger, and the difference between the two is the whole of E3.
        let matches = (1..<closing).filter { isKeyLine(lines[$0], key: key) }
        guard matches.count <= 1 else {
            throw Refusal("`\(key):` appears more than once in the metadata — which one is meant is not something to pick between silently")
        }

        guard let index = matches.first else {
            guard let value else { return source }
            lines.insert("\(key): \(quoted(value))", at: closing)
            return lines.joined(separator: newline)
        }

        // A key whose value is a list or a block has more under it than one line, and
        // replacing the line would leave the rest of it orphaned at the top of the file.
        let parts = split(lines[index], key: key)
        if parts.value.isEmpty, index + 1 < closing, isContinuation(lines[index + 1]) {
            throw Refusal("`\(key):` has a list or a block under it, which this cannot change")
        }
        if parts.value.hasPrefix("[") || parts.value.hasPrefix("{") {
            throw Refusal("`\(key):` is a list, which this cannot change")
        }

        guard let value else {
            lines.remove(at: index)
            return lines.joined(separator: newline)
        }
        // The spacing after the colon and whatever followed the value are the author's,
        // and a diff that moves them is a diff about this app rather than about the
        // change that was asked for.
        lines[index] = "\(key):\(parts.spacing)\(quoted(value))\(parts.trailing)"
        return lines.joined(separator: newline)
    }

    /// Set, change or remove one scalar key in a top-level block of keys: `fast` under
    /// `options:`. `nil` removes it, and the block goes with its last key.
    ///
    /// Held to the same rule as `set`: the block's own indentation is kept, a key that
    /// is there twice or has something under it is refused, and a block written inline
    /// as `{…}` is refused rather than rewritten into a shape its author did not use.
    public static func set(_ key: String, under block: String, to value: String?,
                           in source: String) throws -> String {
        let newline = source.range(of: "\r\n") != nil ? "\r\n" : "\n"
        var lines = source.components(separatedBy: newline)

        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else {
            throw Refusal("This file does not start with a metadata block, and one cannot be invented for it")
        }
        guard let closing = lines.dropFirst().firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == "---"
        }) else {
            throw Refusal("The metadata block is never closed")
        }

        let heads = (1..<closing).filter { isKeyLine(lines[$0], key: block) }
        guard heads.count <= 1 else {
            throw Refusal("`\(block):` appears more than once in the metadata — which one is meant is not something to pick between silently")
        }
        guard let head = heads.first else {
            guard let value else { return source }
            lines.insert(contentsOf: ["\(block):", "  \(key): \(quoted(value))"], at: closing)
            return lines.joined(separator: newline)
        }
        let headValue = split(lines[head], key: block).value
        guard headValue.isEmpty else {
            throw Refusal("`\(block):` is written on one line, which this cannot change")
        }

        // The block is every line after its head that belongs to it; blank lines and
        // comments inside it are kept where they are.
        var end = head + 1
        while end < closing, isContinuation(lines[end]) || lines[end].trimmingCharacters(in: .whitespaces).isEmpty {
            end += 1
        }
        let children = (head + 1)..<end
        let indents = children.compactMap { index -> Int? in
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
            return line.prefix { $0 == " " }.count
        }
        let indent = indents.min() ?? 2
        guard indent > 0 else {
            throw Refusal("`\(block):` has a list under it, which this cannot change")
        }
        let pad = String(repeating: " ", count: indent)

        let matches = children.filter {
            lines[$0].hasPrefix(pad) && isKeyLine(String(lines[$0].dropFirst(indent)), key: key)
        }
        guard matches.count <= 1 else {
            throw Refusal("`\(key):` appears more than once under `\(block):` — which one is meant is not something to pick between silently")
        }

        guard let index = matches.first else {
            guard let value else { return source }
            // After the block's last real line, so a trailing blank stays trailing.
            let last = children.last { !lines[$0].trimmingCharacters(in: .whitespaces).isEmpty } ?? head
            lines.insert("\(pad)\(key): \(quoted(value))", at: last + 1)
            return lines.joined(separator: newline)
        }

        let line = String(lines[index].dropFirst(indent))
        let parts = split(line, key: key)
        if parts.value.isEmpty, index + 1 < end,
           lines[index + 1].prefix(while: { $0 == " " }).count > indent {
            throw Refusal("`\(key):` under `\(block):` has a block under it, which this cannot change")
        }
        if parts.value.hasPrefix("[") || parts.value.hasPrefix("{") {
            throw Refusal("`\(key):` under `\(block):` is a list, which this cannot change")
        }

        guard let value else {
            lines.remove(at: index)
            // The last key gone takes its block with it, unless something the author
            // wrote — a comment — is still under it.
            let remaining = (head + 1)..<(end - 1)
            if remaining.allSatisfy({ lines[$0].trimmingCharacters(in: .whitespaces).isEmpty }) {
                lines.remove(at: head)
            }
            return lines.joined(separator: newline)
        }
        lines[index] = "\(pad)\(key):\(parts.spacing)\(quoted(value))\(parts.trailing)"
        return lines.joined(separator: newline)
    }

    /// Whether this line is `key:` at column zero, as against a key of the same name
    /// nested under something, or a longer key that merely starts the same way.
    private static func isKeyLine(_ line: String, key: String) -> Bool {
        guard line.hasPrefix(key) else { return false }
        return line.dropFirst(key.count).first == ":"
    }

    /// Whether this line belongs to the key above it: indented, or a block sequence's
    /// dash. Either way there is more to the value than the one line.
    private static func isContinuation(_ line: String) -> Bool {
        if line.hasPrefix("-") { return true }
        guard let first = line.first else { return false }
        return first.isWhitespace && !line.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// One `key: value  # comment` line, taken apart so that everything except the
    /// value can be put back exactly as it was.
    private static func split(_ line: String, key: String) -> (spacing: String, value: String, trailing: String) {
        let rest = line.dropFirst(key.count + 1)
        let spacing = String(rest.prefix(while: { $0 == " " || $0 == "\t" }))
        let after = String(rest.dropFirst(spacing.count))

        // A `#` inside quotes is part of the value; a `#` after whitespace, or at the
        // start of what is left, opens a comment.
        var quote: Character?
        var commentStart: String.Index?
        var previous: Character?
        for index in after.indices {
            let character = after[index]
            if let open = quote {
                if character == open { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "#", previous == nil || previous!.isWhitespace {
                commentStart = index
                break
            }
            previous = character
        }

        let valuePart = commentStart.map { String(after[..<$0]) } ?? after
        let comment = commentStart.map { String(after[$0...]) } ?? ""
        let value = String(valuePart.reversed().drop(while: { $0 == " " || $0 == "\t" }).reversed())
        let padding = String(valuePart.dropFirst(value.count))
        return (spacing, value, padding + comment)
    }

    /// A plain scalar where one will do, and a quoted one where it will not.
    ///
    /// Written conservatively: this decides what somebody's file looks like, and a
    /// value that reads back as something else is worse than one wearing quotes it
    /// did not strictly need.
    private static func quoted(_ value: String) -> String {
        let indicators: Set<Character> = ["-", "?", ":", ",", "[", "]", "{", "}", "#",
                                          "&", "*", "!", "|", ">", "'", "\"", "%", "@", "`"]
        let needsQuotes = value.isEmpty
            || value.first!.isWhitespace || value.last!.isWhitespace
            || indicators.contains(value.first!)
            || value.contains(": ") || value.contains(" #")
            || value.contains("\n") || value.contains("\r")
        guard needsQuotes else { return value }
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
