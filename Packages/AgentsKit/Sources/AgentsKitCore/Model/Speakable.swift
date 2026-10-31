import Foundation

/// Turns an agent's reply (Markdown, code, paths, links) into sentences a voice can read
/// (#2322). Voice mode asks the runtime for plain spoken sentences, but a runtime can ignore
/// that, so every reply goes through this before it is spoken.
///
/// The rules come from the #1792 spike's fixture replies: each is one that a reply needed.
/// Code and tables are said to be on the screen, not read; a path says its file name; a
/// link says whose it is; hashes, issue numbers, units, clock times and versions are said
/// as a person says them.
public enum Speakable {
    /// How many sentences may be spoken while a reply is still streaming (#2429).
    public static let longReplySentences = 3

    /// The whole reply, as one speakable string.
    public static func text(_ markdown: String) -> String {
        sentences(markdown).joined(separator: " ")
    }

    /// The reply as sentences, in order, so a voice can start on the first one at once.
    /// `limit`: stop once this many are found, so a long reply is not cleaned to its end
    /// for the few that are said (#2429).
    public static func sentences(_ markdown: String, limit: Int = .max) -> [String] {
        var out: [String] = []
        forEachBlock(markdown) { line in
            let cleaned = clean(line: line)
            if !cleaned.isEmpty { out += split(sentencesIn: cleaned) }
            return out.count < limit
        }
        return Array(out.prefix(limit))
    }

    /// What voice mode says for a reply: every cleaned sentence (#2534).
    public static func spoken(_ markdown: String) -> [String] {
        sentences(markdown)
    }

    // MARK: - Blocks

    /// Code fences and tables become one short line each; every other line stays a line.
    static func blocks(_ markdown: String) -> [String] {
        var out: [String] = []
        forEachBlock(markdown) { out.append($0); return true }
        return out
    }

    /// Gives each line of `blocks`, in order, until `visit` says false: the rest of the
    /// reply is not read.
    static func forEachBlock(_ markdown: String, _ visit: (String) -> Bool) {
        var stopped = false
        func emit(_ line: String) {
            if !stopped, !visit(line) { stopped = true }
        }
        var fence: (language: String, lines: Int)?
        var tableRows = 0
        var tableHeader: [String] = []

        func endTable() {
            guard tableRows > 0 else { return }
            let rows = max(tableRows - 1, 0)
            var line = "A table with \(rows) \(rows == 1 ? "row" : "rows")"
            if !tableHeader.isEmpty { line += ", of " + list(tableHeader) }
            emit(line + ", is on the screen.")
            tableRows = 0
            tableHeader = []
        }

        for raw in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            if stopped { return }
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                if let open = fence {
                    emit(codeLine(open.language, open.lines))
                    fence = nil
                } else {
                    endTable()
                    fence = (String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces), 0)
                }
                continue
            }
            if fence != nil {
                fence?.lines += 1
                continue
            }
            if line.hasPrefix("|") {
                // The line under the header: dashes, colons and bars only.
                if line.allSatisfy({ "|-: ".contains($0) }) { continue }
                if tableRows == 0 {
                    tableHeader = line.split(separator: "|").map { clean(cell: String($0)) }.filter { !$0.isEmpty }
                }
                tableRows += 1
                continue
            }
            endTable()
            // The three-client parity lines are for reviewers, not for the ear.
            if line.range(of: #"^(mac|remote|web): "#, options: .regularExpression) != nil { continue }
            emit(line)
        }
        endTable()
        // A fence the reply never closed (it was cut off): still not read.
        if let open = fence { emit(codeLine(open.language, open.lines)) }
    }

    static func codeLine(_ language: String, _ lines: Int) -> String {
        let what = language.isEmpty ? "A code block" : "A \(spokenLanguage(language)) code block"
        return "\(what), \(lines) \(lines == 1 ? "line" : "lines"), is on the screen."
    }

    /// A header cell, without its markup, so "**Runtime**" is said as "Runtime".
    static func clean(cell: String) -> String {
        cell.replacing(#/\*\*|__|`/#, with: "").trimmingCharacters(in: .whitespaces)
    }

    // MARK: - One line

    static func clean(line: String) -> String {
        var s = line
        // Headings, bullets, numbers and quotes at the start.
        s = s.replacing(#/^#{1,6}\s+/#, with: "")
        s = s.replacing(#/^[-*+]\s+(\[[ xX]\]\s+)?/#, with: "")
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
        // Commit hashes: seven or more hex digits with a letter among them.
        s = s.replacing(#/\b[0-9a-f]{7,40}\b/#) { match in
            match.0.contains(where: \.isLetter) ? "a commit" : String(match.0)
        }
        // Issue and pull request numbers.
        s = s.replacing(#/\b(PR|issue|pull request)\s+#(\d+)/#) { "\($0.1) \($0.2)" }
        s = s.replacing(#/#(\d+)/#) { "number \($0.1)" }
        // Versions, before the clock and the units: "v0.8.0" is not a time or a decimal.
        s = s.replacing(#/\bv?(\d+)\.(\d+)\.(\d+)\b/#) { m in
            let version = "\(m.1) point \(m.2) point \(m.3)"
            return m.0.hasPrefix("v") ? "version " + version : version
        }
        s = s.replacing(#/\bv(\d+)\.(\d+)\b/#) { "version \($0.1) point \($0.2)" }
        // Clock times: "10:42:07" is not ten hours, 42 minutes and 7 seconds.
        s = s.replacing(#/\b([01]?\d|2[0-3]):([0-5]\d)(?::[0-5]\d)?\b/#) { m in
            spokenTime(hour: Int(m.1) ?? 0, minute: Int(m.2) ?? 0)
        }
        // Units a voice reads as letters.
        s = s.replacing(#/\b(\d+) ?ms\b/#) { "\($0.1) milliseconds" }
        s = s.replacing(#/\b(\d+) s\b/#) { $0.1 == "1" ? "1 second" : "\($0.1) seconds" }
        s = s.replacing(#/\b(\d+) ?min\b/#) { $0.1 == "1" ? "1 minute" : "\($0.1) minutes" }
        s = s.replacing(#/\b(\d+(?:\.\d+)?) ?(KB|MB|GB)\b/#) { "\($0.1) \(spokenSize(String($0.2)))" }
        // Names in camel case outside backticks: "wordsPerMinute" is three words.
        s = s.replacing(#/\b[A-Za-z]+[a-z][A-Z][A-Za-z]*\b/#) { m in
            let word = String(m.0)
            return keepsItsCase(word) ? word : splitWords(word)
        }
        // Symbols a voice reads badly.
        s = s.replacing("→", with: " to ").replacing("−", with: " minus ").replacing("±", with: " plus or minus ")
        s = s.replacing("&", with: " and ")
        s = s.replacing(#/\s+/#, with: " ").trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return s }
        if s.hasSuffix(":") { s.removeLast() }
        if let last = s.last, !".!?".contains(last) { s += "." }
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
            c = c.split(separator: "/").last.map(String.init) ?? c
        }
        c = c.replacing("()", with: "")
        var words: String
        if let m = c.firstMatch(of: #/^(.+)\.(swift|go|ts|tsx|js|py|md|json|jsonl|sh|yml|yaml|log|txt|html|css|toml|plist)$/#) {
            words = splitWords(String(m.1).replacing(".", with: " ")) + " dot " + String(m.2)
        } else {
            words = splitWords(c.replacing(".", with: " "))
        }
        if let lineNumber { words += ", line \(lineNumber)" }
        return words
    }

    /// Splits a name at underscores, dashes and each lower-to-upper step.
    static func splitWords(_ s: String) -> String {
        var out = ""
        var previous: Character?
        for ch in s {
            if ch == "_" || ch == "-" {
                out.append(" ")
                previous = " "
                continue
            }
            if let p = previous, ch.isUppercase, p.isLowercase { out.append(" ") }
            out.append(ch)
            previous = ch
        }
        return out.replacing(#/\s+/#, with: " ").trimmingCharacters(in: .whitespaces)
    }

    /// Names whose capitals are part of the name, which a voice already says as one word.
    static let ownCase: Set<String> = [
        "GitHub", "GitLab", "iPhone", "iPad", "iOS", "iPadOS", "macOS", "watchOS", "visionOS",
        "TestFlight", "JavaScript", "TypeScript", "OpenCode", "OpenAI", "ChatGPT", "DeepSeek",
        "PowerShell", "YouTube", "LinkedIn", "AirPods", "FaceTime", "iCloud", "WebSocket",
        "SwiftUI", "AppKit", "UIKit", "CoreML", "FluidAudio", "DigitalOcean", "PostgreSQL",
        "MySQL", "SQLite", "WebKit", "PayPal",
    ]

    /// A name with a capital inside that is said as it is: one in `ownCase`, or one that
    /// starts with a single small letter ("iMessage", "eSIM").
    static func keepsItsCase(_ word: String) -> Bool {
        if ownCase.contains(word) { return true }
        let chars = Array(word)
        return chars.count > 1 && chars[0].isLowercase && chars[1].isUppercase
    }

    /// 10:42 → "10 42", 9:05 → "9 oh 5", 14:00 → "14 hundred".
    static func spokenTime(hour: Int, minute: Int) -> String {
        switch minute {
        case 0: hour > 12 ? "\(hour) hundred" : "\(hour) o'clock"
        case 1..<10: "\(hour) oh \(minute)"
        default: "\(hour) \(minute)"
        }
    }

    static func spokenSize(_ unit: String) -> String {
        switch unit {
        case "KB": "kilobytes"
        case "MB": "megabytes"
        default: "gigabytes"
        }
    }

    static func spokenHost(_ host: String) -> String {
        let h = host.replacing(#/^www\./#, with: "")
        if h.hasPrefix("localhost") || h.hasPrefix("127.0.0.1") { return "this computer" }
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
        case "diff", "patch": "diff"
        default: l.capitalized
        }
    }

    static func list(_ items: [String]) -> String {
        switch items.count {
        case 0: ""
        case 1: items[0]
        default: items.dropLast().joined(separator: ", ") + " and " + (items.last ?? "")
        }
    }

    // MARK: - Sentences

    /// Splits at a full stop, question or exclamation mark followed by a space, but not
    /// after "e.g." and the like.
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
