import Foundation

/// Start Agent on a doc's page, and the Docs section on Work's issue and PR pages (#3322, spec
/// 3319), as the web page's model/docs.ts: the three starts and their prompts, the `doc:` label,
/// the docs an item's body names, and the words its title is searched by.
public extension DocsList {
    /// The three ways Start Agent ▾ starts a session from a doc.
    enum Start: String, CaseIterable, Hashable, Sendable {
        case build, review, ask

        public var title: String {
            switch self {
            case .build: "Build this"
            case .review: "Review this"
            case .ask: "Ask about this"
            }
        }

        public var help: String {
            switch self {
            case .build: "A new session that builds what this doc describes"
            case .review: "A new session that finds what is missing or wrong in this doc, and files it"
            case .ask: "A new session that answers a question about this doc"
            }
        }

        /// The prompt the new-session form opens with. The doc's ref names it, and the session reads
        /// it with `docs_read`. *Ask about this* ends where the person types the question.
        public func prompt(_ ref: String) -> String {
            switch self {
            case .build: "Build what the doc \(ref) describes. Read it with the docs_read tool first."
            case .review:
                "Review the doc \(ref). Read it with the docs_read tool, find what is missing or wrong in it, and file each thing you find as an issue."
            case .ask: "Read the doc \(ref) with the docs_read tool, then answer: "
            }
        }

        /// *Build this* names the doc the session works from (`doc:<short form>`), as `#<n>` names an issue.
        public func labels(_ doc: DaemonAPI.Doc) -> [String] {
            self == .build ? [DocsList.label(doc)] : []
        }
    }

    /// `doc:<short form>`, cut to a session label's length (24): a path keeps its last whole parts
    /// (`doc:3319-docs/spec.md`), a file name too long keeps its end, a title its start.
    static func label(_ doc: DaemonAPI.Doc) -> String {
        let room = SessionLabelPolicy.maximumLength - "doc:".count
        let short = shortForm(doc)
        guard short.count > room else { return "doc:" + short }
        guard doc.path?.isEmpty == false else { return "doc:" + short.prefix(room) }
        var kept = ""
        for part in short.split(separator: "/").reversed() {
            let next = kept.isEmpty ? String(part) : "\(part)/\(kept)"
            guard next.count <= room else { break }
            kept = next
        }
        return "doc:" + (kept.isEmpty ? String(short.suffix(room)) : kept)
    }

    /// The most docs an item's Docs section shows from its body, and from a search for its title.
    static let linkedMost = 10
    static let relatedMost = 3

    /// The docs an issue's or a PR's body names, in its order, each once: a doc's ref, its address
    /// (`#/docs/<ref>`, `agents://docs/<ref>`), and a `specs/` or `docs/` Markdown path, which is a doc
    /// of the item's own repo.
    static func linkedRefs(body: String, itemRef: String) -> [String] {
        // `#/docs/<ref>` (the web page's, its ref encoded) or `agents://docs/<ref>` (the Mac window's).
        let addressPattern = /(?:#\/docs\/|agents:\/\/docs\/)([^\s)\]>`'"]+)/
        // A folder doc's ref (`<scheme>:<repo or machine/folder>/doc/<path>`), or a connector doc's.
        let refPattern =
            /\b(?:[a-z]+:[^\s\/:]+(?:\/[^\s\/]+)+\/doc\/[^\s)\]>`'"]+|(?:confluence|notion|gdrive|mcp):[^\s)\]>`'"]+)/
        // A Markdown path under specs/ or docs/, not inside a longer path or a URL.
        let pathPattern = /(?:^|[^\w\/.:-])((?:specs|docs)\/[\w.\/-]+\.md)\b/
        let repo = repoPrefix(itemRef)
        var found: [(at: String.Index, ref: String)] = []
        for match in body.matches(of: addressPattern) {
            let raw = String(match.output.1)
            found.append((match.range.lowerBound, raw.removingPercentEncoding ?? raw))
        }
        for match in body.matches(of: refPattern) {
            // An address's ref is found once, as the address.
            if match.range.lowerBound > body.startIndex,
               body[body.index(before: match.range.lowerBound)] == "/" { continue }
            found.append((match.range.lowerBound, String(match.output)))
        }
        if let repo {
            for match in body.matches(of: pathPattern) {
                found.append((match.output.1.startIndex, repo + String(match.output.1)))
            }
        }
        var seen = Set<String>()
        return found.sorted { $0.at < $1.at }
            .map { trimmedRef($0.ref) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .prefix(linkedMost).map { $0 }
    }

    /// `github:alexec/agents/doc/` for `github:alexec/agents#12`; nil for an item of no repo.
    static func repoPrefix(_ itemRef: String) -> String? {
        guard let match = itemRef.wholeMatch(of: /([a-z]+:[^\s#!]+\/[^\s#!]+)[#!][0-9]+/) else { return nil }
        return String(match.output.1).lowercased() + "/doc/"
    }

    /// The words an item's title is searched by: its own words of four letters or more, not the
    /// common ones, the longest first. Each is searched alone, since `docs/search` wants every word
    /// on one line.
    static func searchWords(_ title: String, most: Int = 4) -> [String] {
        var seen = Set<String>()
        let words = title.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count >= 4 && !$0.allSatisfy(\.isNumber) && !commonWords.contains($0) && seen.insert($0).inserted }
        return Array(words.enumerated().sorted { a, b in
            a.element.count != b.element.count ? a.element.count > b.element.count : a.offset < b.offset
        }.map(\.element).prefix(most))
    }

    /// The docs most like an item, from one search a word: the most of its words first, then the
    /// most matches; none it links to already. A doc two machines found counts once a word.
    static func related(_ searches: [[DaemonAPI.DocsSearchResult]], leaving linked: Set<String>,
                        most: Int = relatedMost) -> [DaemonAPI.Doc] {
        var score: [String: (words: Int, matches: Int, first: Int, doc: DaemonAPI.Doc)] = [:]
        var order = 0
        for results in searches {
            var seen = Set<String>()
            for result in results where !linked.contains(result.doc.ref) && seen.insert(result.doc.ref).inserted {
                var s = score[result.doc.ref] ?? (0, 0, order, result.doc)
                s.words += 1
                s.matches += result.matches.count
                score[result.doc.ref] = s
                order += 1
            }
        }
        return score.values.sorted { a, b in
            if a.words != b.words { return a.words > b.words }
            if a.matches != b.matches { return a.matches > b.matches }
            return a.first < b.first
        }.prefix(most).map(\.doc)
    }

    private static func trimmedRef(_ ref: String) -> String {
        var ref = ref
        while let last = ref.last, ".,;:!?".contains(last) { ref.removeLast() }
        return ref
    }

    private static let commonWords: Set<String> = [
        "about", "after", "also", "and", "from", "have", "into", "make", "more", "only", "page", "pages", "that",
        "their", "them", "then", "there", "this", "what", "when", "where", "which", "with", "without", "work",
    ]
}
