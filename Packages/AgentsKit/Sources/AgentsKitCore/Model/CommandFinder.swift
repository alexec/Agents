import Foundation

/// The ⌘K command menu (#4787, spec `specs/4777-fast/spec.md`, "⌘K"): one field that finds any
/// session, folder, issue or pull request, by its words or by its ref (`#4777`), and any action,
/// each with its shortcut. The app gives the items; this finds and orders them, so each client
/// that draws the menu finds the same items in the same order.
public enum CommandFinder {
    /// What an item is, which the row says, and which comes first when two match as well.
    public enum Kind: Int, Sendable, Hashable, CaseIterable {
        case action, session, folder, issue, pr

        public var word: String {
            switch self {
            case .action: "Action"
            case .session: "Session"
            case .folder: "Folder"
            case .issue: "Issue"
            case .pr: "Pull request"
            }
        }

        public var symbol: String {
            switch self {
            case .action: "command"
            case .session: "bubble.left"
            case .folder: "folder"
            case .issue: "smallcircle.filled.circle"
            case .pr: "arrow.triangle.pull"
            }
        }
    }

    public struct Item: Sendable, Hashable, Identifiable {
        /// Unique in one menu: `session:<uuid>`, `folder:<path>`, `issue:<ref>`, `action:<name>`.
        public var id: String
        public var kind: Kind
        public var title: String
        /// The grey words after the title: a session's folder, an issue's repo.
        public var detail: String
        /// The ref's short form (`#4777`), matched as typed; empty when the item has none.
        public var ref: String
        /// The shortcut's glyphs (`⌥⌘⌫`), shown at the row's end; empty with none.
        public var shortcut: String
        /// Other words that find it, not shown ("Find Session" for the sessions' search).
        public var keywords: [String]

        public init(id: String, kind: Kind, title: String, detail: String = "", ref: String = "",
                    shortcut: String = "", keywords: [String] = []) {
            self.id = id
            self.kind = kind
            self.title = title
            self.detail = detail
            self.ref = ref
            self.shortcut = shortcut
            self.keywords = keywords
        }
    }

    /// The most rows the menu shows: it is for finding one thing, not for reading a list.
    public static let shown = 50

    /// The items that match `query`, the best first, at most `limit`. With no words, the items
    /// in the order given, which is the app's: what is near the person first.
    ///
    /// Every word typed must be in the item (its title, detail, ref or keywords), as the start
    /// of a word or anywhere in one. A title that starts with the query comes first; then one
    /// where each word starts a word; then the rest. Ties keep the kinds' order, then the
    /// order given.
    public static func matches(_ items: [Item], query: String, limit: Int = shown) -> [Item] {
        let words = Self.words(query)
        guard !words.isEmpty else { return Array(items.prefix(limit)) }
        let whole = words.joined(separator: " ")
        var scored: [(score: Int, at: Int, item: Item)] = []
        for (at, item) in items.enumerated() {
            guard let score = score(item, words: words, whole: whole) else { continue }
            scored.append((score, at, item))
        }
        scored.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.item.kind != $1.item.kind { return $0.item.kind.rawValue < $1.item.kind.rawValue }
            return $0.at < $1.at
        }
        return scored.prefix(limit).map(\.item)
    }

    /// A ref typed alone, `#4777`, `4777`, `!12` or `P#12`: its number and whether it says a pull
    /// request; nil for anything else.
    public static func typedRef(_ query: String) -> (number: Int, pr: Bool?)? {
        var text = query.trimmingCharacters(in: .whitespaces)
        var pr: Bool?
        if text.hasPrefix("P#") || text.hasPrefix("p#") { pr = true; text.removeFirst() }
        if text.hasPrefix("!") { pr = true; text.removeFirst() } else if text.hasPrefix("#") { text.removeFirst() }
        guard !text.isEmpty, text.count <= 9, text.allSatisfy(\.isASCII), let number = Int(text), number > 0 else {
            return nil
        }
        return (number, pr)
    }

    /// For a ref typed alone that no item has: an item for it in each repo the menu knows
    /// (`github:alexec/Agents`), an issue and a pull request unless the ref says which, so
    /// `#4777` opens without its list read first. None for a query that is not a ref.
    public static func refItems(_ query: String, repos: [String], known: [Item]) -> [Item] {
        guard let typed = typedRef(query) else { return [] }
        let have = Set(known.filter { $0.kind == .issue || $0.kind == .pr }.map(\.id))
        var made: [Item] = []
        for repo in repos {
            let separator = repo.hasPrefix("gitlab:") ? "!" : "#"
            let kinds: [Kind] = switch typed.pr {
            case true?: [.pr]
            case false?: [.issue]
            case nil: [.issue, .pr]
            }
            for kind in kinds {
                let ref = "\(repo)\(kind == .pr ? separator : "#")\(typed.number)"
                let id = "\(kind == .pr ? "pr" : "issue"):\(ref)"
                guard !have.contains(id) else { continue }
                made.append(Item(id: id, kind: kind, title: "Open \(kind.word.lowercased()) #\(typed.number)",
                                 detail: ReportValueWords.name(DaemonAPI.LineageNode(kind: "", ref: repo)),
                                 ref: "#\(typed.number)"))
            }
        }
        return made
    }

    // MARK: Matching

    static func words(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// Higher is better; nil when a word is not in the item.
    static func score(_ item: Item, words: [String], whole: String) -> Int? {
        let title = item.title.lowercased()
        let ref = item.ref.lowercased()
        // A ref typed as the item has it, with or without its `#`.
        if !ref.isEmpty, whole == ref || "#" + whole == ref || "p" + ref == whole { return 1000 }
        let haystack = ([title, item.detail.lowercased(), ref] + item.keywords.map { $0.lowercased() })
            .joined(separator: " ")
        let starts = Set(Self.words(haystack).flatMap(wordStarts))
        var allStart = true
        for word in words {
            guard haystack.contains(word) else { return nil }
            if !starts.contains(where: { $0.hasPrefix(word) }) { allStart = false }
        }
        if title.hasPrefix(whole) { return title == whole ? 900 : 800 }
        if allStart { return Self.words(title).contains(where: { $0.hasPrefix(words[0]) }) ? 600 : 500 }
        return 100
    }

    /// A word and the parts after its punctuation, so `sign-in` starts at `in` too and
    /// `alexec/agents#12` at `agents` and `12`.
    private static func wordStarts(_ word: String) -> [String] {
        var starts = [word]
        var rest = Substring(word)
        while let cut = rest.firstIndex(where: { !$0.isLetter && !$0.isNumber }) {
            rest = rest[rest.index(after: cut)...]
            if !rest.isEmpty { starts.append(String(rest)) }
        }
        return starts
    }
}
