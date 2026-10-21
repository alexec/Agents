import Foundation

/// Turns an agent's reply (Markdown, code, paths, links) into text a voice can read.
///
/// A spike for #1792, not the feature. The rules are the ones the ten fixture replies
/// needed; the report says which of them the feature keeps.
public enum Speakable {

    /// The whole reply, as one speakable string.
    public static func text(_ markdown: String) -> String {
        sentences(markdown).joined(separator: " ")
    }

    /// The reply as sentences, in order, so a voice can start on the first one at once.
    public static func sentences(_ markdown: String) -> [String] {
        blocks(markdown)
            .map(clean(line:))
            .filter { !$0.isEmpty }
            .flatMap(split(sentencesIn:))
    }

    // MARK: - Blocks

    /// Code fences and tables become one short line each; every other line stays a line.
    static func blocks(_ markdown: String) -> [String] {
        var out: [String] = []
        var fence: (language: String, lines: Int)?
        var tableRows = 0
        var tableHeader: [String] = []

        func endTable() {
            guard tableRows > 0 else { return }
            let rows = max(tableRows - 1, 0)
            var line = "A table with \(rows) \(rows == 1 ? "row" : "rows")"
            if !tableHeader.isEmpty { line += ", of " + list(tableHeader) }
            out.append(line + ".")
            tableRows = 0
            tableHeader = []
        }

        for raw in markdown.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                if let open = fence {
                    let what = open.language.isEmpty ? "A code block" : "A \(spokenLanguage(open.language)) code block"
                    out.append("\(what), \(open.lines) \(open.lines == 1 ? "line" : "lines"), is on the screen.")
                    fence = nil
                } else {
                    endTable()
                    fence = (String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces), 0)
                }
                continue
            }
            if fence != nil { fence!.lines += 1; continue }
            if line.hasPrefix("|") {
                if line.contains("---") { continue }
                if tableRows == 0 {
                    tableHeader = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                }
                tableRows += 1
                continue
            }
            endTable()
            // The three-client parity lines are for reviewers, not for the ear.
            if line.range(of: #"^(mac|remote|web): "#, options: .regularExpression) != nil { continue }
            out.append(line)
        }
        endTable()
        if let open = fence { out.append("A code block, \(open.lines) lines.") }
        return out
    }

    // MARK: - One line

    static func clean(line: String) -> String {
        var s = line
        // Headings, bullets, numbers and quotes at the start.
        s = s.replacing(#/^#{1,6}\s+/#, with: "")
        s = s.replacing(#/^[-*+]\s+/#, with: "")
        s = s.replacing(#/^>\s?/#, with: "")
        s = s.replacing(#/^(\d+)[.)]\s+/#) { "\($0.1): " }
        // Links: keep the words, drop the address.
        s = s.replacing(#/!?\[([^\]]*)\]\([^)]*\)/#) { String($0.1) }
        // A bare address: say whose it is.
        s = s.replacing(#/https?://([^/\s)]+)[^\s)]*?([.,;:]?)(?=\s|\)|$)/#) {
            "a link on \(spokenHost(String($0.1)))\($0.2)"
        }
        // Inline code: a path says its file name, anything else its words.
        s = s.replacing(#/`([^`]+)`/#) { spokenCode(String($0.1)) }
        // Paths and file names left outside backticks.
        s = s.replacing(#/(?:~|\.{1,2})?(?:/[\w.@-]+){2,}/?(?::\d+)?/#) { spokenCode(String($0.0)) }
        // Emphasis.
        s = s.replacing(#/\*\*|__/#, with: "")
        s = s.replacing(#/(^|\s)[*_]([^*_\s][^*_]*?)[*_](?=\s|[.,;:!?]|$)/#) { "\($0.1)\($0.2)" }
        // Commit hashes.
        s = s.replacing(#/\b[0-9a-f]{7,40}\b/#) { match in
            match.0.contains(where: \.isLetter) ? "a commit" : String(match.0)
        }
        // Issue and pull request numbers.
        s = s.replacing(#/\b(PR|issue|pull request)\s+#(\d+)/#) { "\($0.1) \($0.2)" }
        s = s.replacing(#/#(\d+)/#) { "number \($0.1)" }
        // Units a voice reads as letters.
        s = s.replacing(#/\b(\d+) ms\b/#) { "\($0.1) milliseconds" }
        s = s.replacing(#/\b(\d+) s\b/#) { $0.1 == "1" ? "1 second" : "\($0.1) seconds" }
        s = s.replacing(#/\b(\d+) min\b/#) { $0.1 == "1" ? "1 minute" : "\($0.1) minutes" }
        // Symbols a voice reads badly.
        s = s.replacing("→", with: " to ").replacing("−", with: " minus ").replacing("±", with: " plus or minus ")
        s = s.replacing(#/\s+/#, with: " ").trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return s }
        if let last = s.last, !".!?:".contains(last) { s += "." }
        if s.hasSuffix(":") { s.removeLast(); s += "." }
        return s
    }

    /// `Shared/UI/Chat/Dictation.swift:142` → "Dictation dot swift, line 142";
    /// `DictationTests.testStartTwice` → "Dictation Tests test Start Twice".
    static func spokenCode(_ code: String) -> String {
        var c = code.trimmingCharacters(in: .whitespaces)
        // A command line is not read out.
        if c.contains(" ") && (c.contains("$") || c.contains("/") || c.range(of: #"^[a-z][\w.-]*\s+-"#, options: .regularExpression) != nil) {
            return "a command"
        }
        var lineNumber: String?
        if let m = c.firstMatch(of: #/:(\d+)(?::\d+)?$/#) {
            lineNumber = String(m.1)
            c = String(c[..<m.range.lowerBound])
        }
        if c.contains("/") {
            let parts = c.split(separator: "/").filter { !$0.isEmpty }
            c = parts.last.map(String.init) ?? c
            if c.hasPrefix("agents-") || parts.first == "agents" { c = c.replacing("-", with: " ") }
        }
        c = c.replacing("()", with: "")
        var words = c
        if let m = words.firstMatch(of: #/^(.+)\.(swift|go|ts|tsx|js|py|md|json|jsonl|sh|yml|yaml|log|txt|html|css)$/#) {
            words = splitWords(String(m.1).replacing(".", with: " ")) + " dot " + String(m.2)
        } else {
            words = splitWords(words.replacing(".", with: " "))
        }
        if let lineNumber { words += ", line \(lineNumber)" }
        return words
    }

    static func splitWords(_ s: String) -> String {
        var out = ""
        var previous: Character?
        for ch in s {
            if ch == "_" || ch == "-" { out.append(" "); previous = " "; continue }
            if let p = previous, ch.isUppercase, p.isLowercase { out.append(" ") }
            out.append(ch)
            previous = ch
        }
        return out.replacing(#/\s+/#, with: " ").trimmingCharacters(in: .whitespaces)
    }

    static func spokenHost(_ host: String) -> String {
        let h = host.replacing(#/^www\./#, with: "")
        if h.hasPrefix("localhost") || h.hasPrefix("127.0.0.1") { return "this Mac" }
        return h.split(separator: ".").dropLast().last.map(String.init)?.capitalized ?? h
    }

    static func spokenLanguage(_ l: String) -> String {
        switch l.lowercased() {
        case "sh", "bash", "zsh", "shell", "console": "shell"
        case "ts", "tsx", "typescript": "TypeScript"
        case "js", "javascript": "JavaScript"
        case "py", "python": "Python"
        case "json", "jsonl": "JSON"
        case "yml", "yaml": "YAML"
        default: l.capitalized
        }
    }

    static func list(_ items: [String]) -> String {
        switch items.count {
        case 0: ""
        case 1: items[0]
        default: items.dropLast().joined(separator: ", ") + " and " + items.last!
        }
    }

    // MARK: - Sentences

    /// Splits at a full stop, question or exclamation mark followed by a space,
    /// but not inside "e.g." or a number like 0.8.
    static func split(sentencesIn line: String) -> [String] {
        var out: [String] = []
        var current = ""
        let chars = Array(line)
        for (i, ch) in chars.enumerated() {
            current.append(ch)
            guard ".!?".contains(ch) else { continue }
            let next = i + 1 < chars.count ? chars[i + 1] : " "
            guard next == " " else { continue }
            let word = current.split(separator: " ").last.map(String.init) ?? ""
            if ["e.g.", "i.e.", "etc.", "vs."].contains(word.lowercased()) { continue }
            out.append(current.trimmingCharacters(in: .whitespaces))
            current = ""
        }
        let rest = current.trimmingCharacters(in: .whitespaces)
        if !rest.isEmpty { out.append(rest) }
        return out
    }
}
