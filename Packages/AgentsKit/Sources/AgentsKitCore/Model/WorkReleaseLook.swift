import Foundation

/// A release in the Work look (#4421, `specs/4328-work-look/milestones.md`, Releases): its row,
/// its page's state line, its pull requests and its pipeline, from what lineage knows. A
/// release is a version tag (`v0.42.0`) whose pull requests lineage linked `part-of` it; the
/// forge's releases (`forge/releases`, #4426) bring the name, the notes, the author, drafts and
/// pre-releases.
public enum WorkReleaseLook {
    public typealias Row = WorkList.Row

    /// A version tag's numbers: [0, 42, 0] of "v0.42.0"; nil for a tag that is not a version.
    public static func version(_ tag: String) -> [Int]? {
        let digits = tag.hasPrefix("v") ? tag.dropFirst() : Substring(tag)
        let parts = digits.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
        return parts.compactMap { $0 }
    }

    /// Whether tag `a` is a later version than `b`; a tag that is not a version is older than one that is.
    public static func newer(_ a: String, than b: String) -> Bool {
        switch (version(a), version(b)) {
        case let (x?, y?): y.lexicographicallyPrecedes(x)
        case (.some, nil): true
        default: false
        }
    }

    /// The tag of a release's ref: "v0.42.0" of "github:alexec/Agents/release/v0.42.0".
    public static func tag(_ ref: String) -> String { WorkList.shortRef(ref) }

    /// The refs of the latest release of each repo: the highest version (milestones.md note 19).
    public static func latest(_ rows: [Row]) -> Set<String> {
        var best: [String: Row] = [:]
        for row in rows where version(tag(row.node.ref)) != nil {
            if let had = best[row.repo], !newer(tag(row.node.ref), than: tag(had.node.ref)) { continue }
            best[row.repo] = row
        }
        return Set(best.values.map(\.node.ref))
    }

    /// The release before `ref` in its repo: the highest version under its own; nil for the first.
    public static func previous(of ref: String, in rows: [Row]) -> Row? {
        let repo = WorkList.repo(of: ref)
        let mine = tag(ref)
        guard version(mine) != nil else { return nil }
        return rows.filter { $0.repo == repo && newer(mine, than: tag($0.node.ref)) && version(tag($0.node.ref)) != nil }
            .max { newer(tag($1.node.ref), than: tag($0.node.ref)) }
    }

    /// "v0.41.0…v0.42.0" (note 23).
    public static func rangeWords(from previous: String, to tag: String) -> String { "\(previous)…\(tag)" }

    /// The forge's compare page between two tags; nil for a forge whose address the ref does not say.
    public static func compareURL(_ ref: String, from previous: String) -> URL? {
        let repo = WorkList.repo(of: ref)
        guard repo.hasPrefix("github:") else { return nil }
        return URL(string: "https://github.com/\(repo.dropFirst("github:".count))/compare/\(previous)...\(tag(ref))")
    }

    /// "1 pull request", "23 pull requests".
    public static func pullsWords(_ n: Int) -> String { n == 1 ? "1 pull request" : "\(n) pull requests" }

    /// When it was released, as lineage has it: its links are at the tag's commit time.
    /// Wide: "released 2 h ago"; on a phone: "2 h".
    public static func releasedWords(_ at: Date, compact: Bool, now: Date = Date()) -> String {
        let age = WorkLook.ageWords(now.timeIntervalSince(at))
        if compact { return age }
        return age == "now" ? "released now" : "released \(age) ago"
    }

    /// The page's state line after its pill (note 23), the range apart, as it is a link:
    /// "released 2 h ago · 23 pull requests".
    public static func stateWords(released: Date?, pulls: Int?, compact: Bool, now: Date = Date()) -> String {
        [released.map { releasedWords($0, compact: compact, now: now) }, pulls.map(pullsWords)]
            .compactMap { $0 }.joined(separator: " · ")
    }

    /// The pull requests lineage linked `part-of` the release, the newest number first, each with
    /// what its forge said of it (title, state and labels) where a machine resolved it.
    public static func pullRequests(of release: DaemonAPI.LineageNode, in graph: DaemonAPI.LineageGraph) -> [Row] {
        var seen = Set<String>()
        var rows: [Row] = []
        for link in graph.links where link.rel == "part-of" && link.to == release && link.from.kind == "pr" {
            let pr = link.from
            guard seen.insert(pr.ref).inserted else { continue }
            let resolved = graph.resolved?[pr.ref]
            rows.append(Row(node: pr, title: resolved?.title ?? WorkList.shortRef(pr.ref), state: resolved?.state ?? "merged",
                            labels: (resolved?.labels ?? []).map { DaemonAPI.ForgeLabel(name: $0) },
                            repo: WorkList.repo(of: pr.ref), updated: link.endedAt ?? link.at, url: WorkList.url(pr)))
        }
        return WorkList.sort(rows, by: .newest)
    }

    /// One stage of a release's pipeline on its page (note 28): the CI run that built it, then
    /// each deploy (TestFlight, the App Store, Cloud Run), with its address outside Agents.
    public struct Stage: Hashable, Sendable {
        public var words: String
        public var url: URL?
    }

    /// The stages lineage reached from the release; empty when it knows none. Lineage records a
    /// stage once it got there, so each one shown is done; one still running comes with #3588.
    public static func pipeline(of release: DaemonAPI.LineageNode, in graph: DaemonAPI.LineageGraph) -> [Stage] {
        var seen = Set<DaemonAPI.LineageNode>()
        let runs = graph.links.filter { $0.rel == "builds" && $0.to == release && $0.from.kind == "ci-run" }.map(\.from)
        let deploys = graph.links.filter { $0.rel == "deployed-as" && $0.from == release && $0.to.kind == "deploy" }.map(\.to)
        return (runs + deploys).filter { seen.insert($0).inserted }.map { n in
            Stage(words: n.kind == "ci-run" ? "CI run" : Pipeline.words(n), url: Pipeline.url(n))
        }
    }

    /// Lineage's line on the panel (note 29): "$18.40 · 3 sessions, 1 running · lead time 2h 10m",
    /// from `lineage/figures`; nil with none.
    public static func lineageWords(_ f: DaemonAPI.LineageFigures) -> String? {
        var parts: [String] = []
        if ReportValueWords.spent(f.cost) { parts.append(ReportValueWords.cost(f.cost)) }
        if f.sessions > 0 {
            let sessions = f.sessions == 1 ? "1 session" : "\(f.sessions) sessions"
            parts.append(f.running > 0 ? "\(sessions), \(f.running) running" : sessions)
        }
        if let lead = f.leadTimeSeconds { parts.append("lead time \(TimeChart.words(lead))") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The runtimes that worked on it: "Claude 3 · Codex 1".
    public static func runtimesWords(_ f: DaemonAPI.LineageFigures) -> String? {
        guard !f.runtimes.isEmpty else { return nil }
        return f.runtimes.map { "\(PoolWords.runtimeName($0.runtimeID)) \($0.sessions)" }.joined(separator: " · ")
    }

    /// Where the notes are, until Agents reads them (#4426): "The notes are on GitHub."
    public static func notesElsewhere(_ ref: String) -> String { "The release notes are on \(WorkList.forgeName(ref))." }

    public static let noPulls = "Lineage links no pull request to this release. The first version tag of a repo links none."
    public static let noPipeline = "No CI run or deploy in lineage yet."
}
