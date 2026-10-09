import Foundation

/// What the app says about a turn the agent did not account for itself (#479).
///
/// Agents are no longer told to call `finish_turn`. Runtimes forgot it, called it and
/// carried on, wrote too much in it, and when they skipped it the app spent a whole
/// extra turn asking. What the row shows is worked out instead from what the daemon
/// already has: how the turn stopped, whether a question is open, and the agent's own
/// closing words. A `finish_turn` call still wins over all of this.
///
/// Only a clean `end_turn` is derived here. Every other ending — cancelled, refused,
/// out of tokens, a sandbox that would not start, a runtime that died — already has its
/// own wording in `EndedReason`, and that is what the row says.
public enum DerivedEnding {
    /// The most the derived sentence may be: one sidebar line.
    public static let summaryLimit = 100

    /// What a clean end says, with nothing open, when the agent said nothing at all.
    public static let silentDone = "Finished."

    /// How the work went: waiting on the person when a question is open or the agent's
    /// last words ask one, and done otherwise.
    public static func outcome(closingWords: String?, questionOpen: Bool) -> WorkOutcome {
        if questionOpen { return .needsAnswer }
        return endsInAQuestion(closingWords) ? .needsAnswer : .done
    }

    /// The report for a clean end that said nothing about itself.
    public static func report(closingWords: String?, questionOpen: Bool, at: Date) -> WorkReport {
        let outcome = outcome(closingWords: closingWords, questionOpen: questionOpen)
        return WorkReport(outcome: outcome, message: message(closingWords: closingWords, outcome: outcome),
                          at: at)
    }

    /// The line under the agent's name, from its closing words: the first sentence, or
    /// the question when it waits on one. Also what an outcome given with no words of
    /// its own reads, once the turn has ended.
    public static func message(closingWords: String?, outcome: WorkOutcome) -> String {
        // A question is the thing to read on the row, so it is the sentence kept.
        let sentence = outcome == .needsAnswer && endsInAQuestion(closingWords)
            ? lastSentence(of: closingWords ?? "")
            : firstSentence(of: closingWords ?? "")
        return sentence.map(trimmed) ?? (outcome == .done ? silentDone : outcome.heading)
    }

    /// A first title for a conversation, from the words that began it: the first line,
    /// cut short. Set once, where nothing has named the conversation yet.
    public static func title(fromPrompt prompt: String) -> String? {
        let line = plainLines(prompt).first ?? ""
        let words = line.split(whereSeparator: \.isWhitespace)
        let few = words.prefix(8).joined(separator: " ")
        guard !few.isEmpty else { return nil }
        let title = few.count > 60 ? String(few.prefix(59)) + "…" : few + (words.count > 8 ? "…" : "")
        return Agent.cleanedTitle(title)
    }

    // MARK: Sentences

    static func endsInAQuestion(_ words: String?) -> Bool {
        guard let last = plainLines(words ?? "").last else { return false }
        return last.hasSuffix("?")
    }

    /// The first sentence of the first line of prose: headings' marks, list bullets and
    /// emphasis taken off, code fences skipped.
    public static func firstSentence(of words: String) -> String? {
        guard let line = plainLines(words).first else { return nil }
        return sentences(in: line).first
    }

    static func lastSentence(of words: String) -> String? {
        guard let line = plainLines(words).last else { return nil }
        return sentences(in: line).last
    }

    /// One line, at most `summaryLimit` characters, cut at a word where it can be.
    static func trimmed(_ sentence: String) -> String {
        guard sentence.count > summaryLimit else { return sentence }
        let cut = sentence.prefix(summaryLimit - 1)
        let atWord = cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut
        let kept = atWord.count >= summaryLimit / 2 ? atWord : cut
        return kept.trimmingCharacters(in: .whitespaces.union(.punctuationCharacters)) + "…"
    }

    private static func sentences(in line: String) -> [String] {
        var found: [String] = []
        var current = ""
        let characters = Array(line)
        for (index, character) in characters.enumerated() {
            current.append(character)
            guard ".!?".contains(character) else { continue }
            // An ending is punctuation followed by a space or the end of the line, so
            // "e.g" or "1.5" or a path is not cut.
            let next = index + 1 < characters.count ? characters[index + 1] : nil
            guard next == nil || next == " " else { continue }
            let sentence = current.trimmingCharacters(in: .whitespaces)
            if !sentence.isEmpty { found.append(sentence) }
            current = ""
        }
        let rest = current.trimmingCharacters(in: .whitespaces)
        if !rest.isEmpty { found.append(rest) }
        return found
    }

    /// The lines of prose, as plain text, outside any code fence.
    private static func plainLines(_ words: String) -> [String] {
        var inFence = false
        var lines: [String] = []
        for raw in words.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") || line.hasPrefix("~~~") { inFence.toggle(); continue }
            guard !inFence else { continue }
            let plain = plain(line)
            if !plain.isEmpty { lines.append(plain) }
        }
        return lines
    }

    private static func plain(_ line: String) -> String {
        var text = Substring(line)
        // Block marks at the start: headings, quotes, bullets, numbered items.
        while let first = text.first, "#>-*+".contains(first) {
            // A bullet is its mark and a space: "**Bold**" and "-1" are words.
            if "-*+".contains(first), text.dropFirst().first != " " { break }
            text = text.dropFirst().drop { $0 == " " }
        }
        if let dot = text.firstIndex(where: { $0 == "." || $0 == ")" }),
           text[..<dot].allSatisfy(\.isNumber), !text[..<dot].isEmpty,
           text.index(after: dot) < text.endIndex, text[text.index(after: dot)] == " " {
            text = text[text.index(after: dot)...].drop { $0 == " " }
        }
        // Emphasis and inline code marks; the words stay.
        let stripped = String(text)
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")
            .replacingOccurrences(of: "`", with: "")
        return stripped.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
