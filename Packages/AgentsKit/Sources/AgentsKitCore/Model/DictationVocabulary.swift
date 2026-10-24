import Foundation

/// Words given to the on-device transcriber so a name it has never seen is still heard
/// as that name (#2515).
///
/// Apple asks for short strings, and for fewer than about a hundred of them. The
/// product's own words come first, so a long folder cannot push GitHub off the list.
/// A title that is a sentence is left out: it is not a name.
public enum DictationVocabulary {
    /// How many strings go to the transcriber.
    public static let limit = 80
    /// A name, not a sentence.
    public static let maxWords = 4
    public static let maxLength = 40

    /// The product's words, then the runtimes this app can start. Gemini and Antigravity
    /// are here with the ones Alex named, because a person says the runtime they start.
    public static let productTerms: [String] = [
        "GitHub", "GitLab", "TestFlight", "worktree", "lane", "milestone",
        "merge wave", "Scrum Master", "control plane",
        RuntimeCatalog.claude.name,
        RuntimeCatalog.codex.name,
        RuntimeCatalog.copilot.name,
        RuntimeCatalog.cursor.name,
        RuntimeCatalog.grok.name,
        RuntimeCatalog.opencode.name,
        RuntimeCatalog.gemini.name,
        RuntimeCatalog.antigravity.name,
    ]

    /// The product's words, then `extra`, with duplicates and long strings dropped.
    public static func merging(_ extra: [String]) -> [String] {
        combine(productTerms + extra)
    }

    /// What voice mode and the dictate button seed: the open folders' names, the
    /// selected folder's session titles, and its issue numbers.
    ///
    /// Issue numbers are the ones on those sessions. The app does not keep GitHub's
    /// own list. A label that is a number, or "#2515" inside a title, is one.
    public static func seeds(folders: [DaemonAPI.FolderSummary], agents: [Agent], in folder: URL?) -> [String] {
        let names = folders.filter { $0.folder.archivedAt == nil }.flatMap {
            [$0.name, $0.folder.folder.lastPathComponent]
        }
        let wanted = folder.map(Folder.standardize)
        let live = agents.filter { agent in
            guard agent.state != .archived, let wanted else { return false }
            return Folder.standardize(agent.folderPath) == wanted
        }
        var titles: [String] = []
        var issues: [String] = []
        for agent in live {
            if let title = agent.title { titles.append(title) }
            for label in agent.labels {
                if let number = issueNumber(label.value) { issues.append(number) }
            }
            if let title = agent.title { issues += issueNumbers(in: title) }
        }
        return merging(names + titles + issues)
    }

    /// A label that is only an issue number, with or without "#". Three to six digits.
    public static func issueNumber(_ label: String) -> String? {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        guard (3...6).contains(digits.count), digits.allSatisfy(\.isNumber) else { return nil }
        return digits
    }

    /// "#2515" inside a title or a sentence. The number, without the mark.
    public static func issueNumbers(in text: String) -> [String] {
        text.matches(of: /#(\d{3,6})\b/).map { String($0.output.1) }
    }

    private static func combine(_ words: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for raw in words {
            let word = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !word.isEmpty, word.count <= maxLength else { continue }
            guard word.split(whereSeparator: { $0.isWhitespace }).count <= maxWords else { continue }
            guard seen.insert(word.lowercased()).inserted else { continue }
            result.append(word)
            if result.count == limit { break }
        }
        return result
    }
}
