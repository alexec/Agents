import Foundation

/// Work (#3119, spec 3100): every issue and pull request across the person's folders and forges,
/// from `forge/issues` and `forge/pulls` on each machine, one row per ref, with what lineage knows
/// about it (`reports/nodes`: cost, sessions, lead time) on top. Milestones and releases come from
/// `reports/nodes` alone in v1. The web page's `model/work.ts` is the same.
public enum WorkList {
    /// Work's lists, in the order of its tabs, by the lineage kind each holds.
    public enum Kind: String, CaseIterable, Identifiable, Sendable, Hashable, Codable {
        case issue, pr, milestone, release

        public var id: Self { self }

        public var title: String {
            switch self {
            case .issue: "Issues"
            case .pr: "Pull requests"
            case .milestone: "Milestones"
            case .release: "Releases"
            }
        }

        /// Issues and PRs are read from the forges; milestones and releases from lineage alone.
        public var fromForge: Bool { self == .issue || self == .pr }

        /// The states a list can be narrowed to: a PR's merged is its own.
        public var states: [State] { self == .pr ? [.open, .merged, .closed, .all] : [.open, .closed, .all] }

        public var sorts: [Sort] { fromForge ? Sort.allCases : [.updated, .cost] }
    }

    public enum State: String, CaseIterable, Sendable, Hashable {
        case open, closed, merged, all

        public var title: String { self == .all ? "All" : rawValue.capitalized }

        /// The forge's own: closed includes merged, and is told apart here.
        public var forge: String { self == .open ? "open" : self == .all ? "all" : "closed" }
    }

    public enum Sort: String, CaseIterable, Sendable, Hashable {
        case updated, newest, cost

        public var title: String {
            switch self {
            case .updated: "Last updated"
            case .newest: "Newest"
            case .cost: "Cost"
            }
        }
    }

    /// One row: the item as its forge says it, or as lineage resolved it, and its lineage.
    public struct Row: Sendable, Hashable, Identifiable {
        public var node: DaemonAPI.LineageNode
        public var title: String
        /// open, closed or merged; empty when nothing says.
        public var state: String
        public var labels: [DaemonAPI.ForgeLabel]
        /// The ref's repo or tracker: github:alexec/Agents, linear.
        public var repo: String
        public var author: String?
        public var assignees: [String]
        public var milestone: String?
        public var updated: Date
        public var url: URL?
        /// The machine the forge read came from, to read the item again on.
        public var host: MachineRef?
        public var draft: Bool
        public var lineage: DaemonAPI.ReportNode?

        public var id: String { node.ref }

        public init(node: DaemonAPI.LineageNode, title: String, state: String, labels: [DaemonAPI.ForgeLabel] = [],
                    repo: String, author: String? = nil, assignees: [String] = [], milestone: String? = nil,
                    updated: Date, url: URL? = nil, host: MachineRef? = nil, draft: Bool = false,
                    lineage: DaemonAPI.ReportNode? = nil) {
            self.node = node
            self.title = title
            self.state = state
            self.labels = labels
            self.repo = repo
            self.author = author
            self.assignees = assignees
            self.milestone = milestone
            self.updated = updated
            self.url = url
            self.host = host
            self.draft = draft
            self.lineage = lineage
        }

        /// A row from the forge's item, with its lineage when there is any.
        public init(_ item: DaemonAPI.ForgeItem, on host: MachineRef, lineage: DaemonAPI.ReportNode? = nil) {
            self.init(node: item.node, title: item.title, state: item.state, labels: item.labels, repo: WorkList.repo(of: item.node.ref),
                      author: item.author, assignees: item.assignees, milestone: item.milestone, updated: item.updatedAt,
                      url: item.url.flatMap(URL.init(string:)), host: host, draft: item.draft ?? false, lineage: lineage)
        }

        /// A row lineage alone knows: a milestone, a release.
        public init(_ n: DaemonAPI.ReportNode) {
            self.init(node: n.node, title: n.resolved?.title ?? ReportValueWords.name(n.node),
                      state: n.resolved?.state ?? (n.outcome == "merged" ? "merged" : ""),
                      labels: (n.resolved?.labels ?? []).map { DaemonAPI.ForgeLabel(name: $0) },
                      repo: n.project ?? WorkList.repo(of: n.node.ref), updated: n.lastAt,
                      url: WorkList.url(n.node), lineage: n)
        }
    }

    /// The repo or tracker of a ref: "github:alexec/Agents" of "github:alexec/Agents#12", "linear" of "linear:ENG-4".
    public static func repo(of ref: String) -> String {
        guard let colon = ref.firstIndex(of: ":") else { return ref }
        let forge = String(ref[..<colon])
        if forge == "linear" || forge == "jira" { return forge }
        let id = ref[ref.index(after: colon)...]
        guard let cut = id.range(of: #"[#!]|/milestone/|/release/"#, options: .regularExpression) else { return ref }
        return "\(forge):\(id[..<cut.lowerBound])"
    }

    /// Where a node is on its forge, as far as its ref says: a PR's is its /pull/ page.
    public static func url(_ node: DaemonAPI.LineageNode) -> URL? {
        ReportValueWords.url(node).map { LineageList.pullRequest(node, $0) }
    }

    /// "alexec/Agents" of "github:alexec/Agents".
    public static func repoName(_ repo: String) -> String {
        repo.replacingOccurrences(of: #"^[a-z][a-z0-9-]*:"#, with: "", options: .regularExpression)
    }

    /// An issue's or a PR's number in its repo, for Newest; 0 for one without.
    public static func number(_ ref: String) -> Int {
        guard let range = ref.range(of: #"[#!-]\d+$"#, options: .regularExpression) else { return 0 }
        return Int(ref[range].dropFirst()) ?? 0
    }

    /// "#12", "!45", "ENG-4", "milestone 2" or "v0.14.0": a row's short name in its repo.
    public static func shortRef(_ ref: String) -> String {
        if let range = ref.range(of: #"[#!]\d+$"#, options: .regularExpression) { return String(ref[range]) }
        if let range = ref.range(of: #"/milestone/.+$"#, options: .regularExpression) {
            return "milestone " + ref[range].dropFirst("/milestone/".count)
        }
        if let range = ref.range(of: #"/release/.+$"#, options: .regularExpression) {
            return String(ref[range].dropFirst("/release/".count))
        }
        return ReportValueWords.name(DaemonAPI.LineageNode(kind: "", ref: ref))
    }

    /// Whether a title says its short name already, as a milestone lineage could not resolve does.
    public static func titleSaysRef(_ title: String, _ ref: String) -> Bool { title.hasSuffix(shortRef(ref)) }

    /// The items of every machine, one row per ref (the last updated copy), each with its lineage by ref.
    public static func merge(_ lists: [(host: MachineRef, items: [DaemonAPI.ForgeItem])],
                             lineage: [DaemonAPI.ReportNode]) -> [Row] {
        let byRef = Dictionary(lineage.map { ($0.node.ref, $0) }, uniquingKeysWith: { first, _ in first })
        var rows: [String: Row] = [:]
        for (host, items) in lists {
            for item in items {
                let row = Row(item, on: host, lineage: byRef[item.node.ref])
                if let had = rows[item.node.ref], had.updated >= row.updated { continue }
                rows[item.node.ref] = row
            }
        }
        return Array(rows.values)
    }

    /// What a list is narrowed to. Empty repo, label, assignee or text is any.
    public struct Filter: Sendable, Hashable {
        public var state: State
        public var repo: String
        public var label: String
        public var assignee: String
        public var text: String

        public init(state: State = .open, repo: String = "", label: String = "", assignee: String = "", text: String = "") {
            self.state = state
            self.repo = repo
            self.label = label
            self.assignee = assignee
            self.text = text
        }
    }

    /// Whether a row is in the state asked: a merged PR is merged, not closed.
    public static func matches(_ row: Row, state: State) -> Bool {
        switch state {
        case .all: true
        case .closed: row.state == "closed" || (row.node.kind != "pr" && row.state == "merged")
        case .open, .merged: row.state == state.rawValue
        }
    }

    public static func filter(_ rows: [Row], _ f: Filter) -> [Row] {
        let words = f.text.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        return rows.filter { r in
            guard matches(r, state: f.state) else { return false }
            if !f.repo.isEmpty, r.repo != f.repo { return false }
            if !f.label.isEmpty, !r.labels.contains(where: { $0.name == f.label }) { return false }
            if !f.assignee.isEmpty, !r.assignees.contains(f.assignee) { return false }
            guard !words.isEmpty else { return true }
            let hay = ([r.title, r.node.ref] + r.labels.map(\.name)).joined(separator: " ").lowercased()
            return words.allSatisfy(hay.contains)
        }
    }

    /// The total cost in one figure, for sorting: the sum of its currencies.
    private static func cost(_ r: Row) -> Decimal { r.lineage?.cost.total.cost.values.reduce(0, +) ?? 0 }

    public static func sort(_ rows: [Row], by sort: Sort) -> [Row] {
        let tie: (Row, Row) -> Bool = { a, b in a.updated != b.updated ? a.updated > b.updated : a.node.ref < b.node.ref }
        switch sort {
        case .updated:
            return rows.sorted(by: tie)
        case .newest:
            // A forge numbers its items as they are made, so the highest number is the newest.
            return rows.sorted { a, b in
                let (x, y) = (number(a.node.ref), number(b.node.ref))
                return x != y ? x > y : tie(a, b)
            }
        case .cost:
            // With no lineage last; among those, the last updated first.
            return rows.sorted { a, b in
                let (x, y) = (cost(a), cost(b))
                if x != y { return x > y }
                if (a.lineage != nil) != (b.lineage != nil) { return a.lineage != nil }
                return tie(a, b)
            }
        }
    }

    /// The choices of a filter's menu, from the rows read: their repos, labels and assignees, sorted.
    public static func choices(_ rows: [Row]) -> (repos: [String], labels: [String], assignees: [String]) {
        (Set(rows.map(\.repo)).sorted(), Set(rows.flatMap { $0.labels.map(\.name) }).sorted(),
         Set(rows.flatMap(\.assignees)).sorted())
    }

    /// Lead time in days and hours: "1d 4h", "3h 10m".
    public static func leadWords(_ seconds: Double) -> String {
        let days = Int(seconds / 86_400)
        if days == 0 {
            let minutes = Int((seconds / 60).rounded())
            if minutes < 60 { return "\(max(minutes, 0))m" }
            return minutes % 60 == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h \(minutes % 60)m"
        }
        let hours = Int(seconds.truncatingRemainder(dividingBy: 86_400) / 3600)
        return hours == 0 ? "\(days)d" : "\(days)d \(hours)h"
    }

    /// What lineage knows about a row: "3 sessions · $4.10 · waste $0.60 · lead time 1d 4h"; nil with none.
    public static func lineageWords(_ n: DaemonAPI.ReportNode?) -> String? {
        guard let n else { return nil }
        var parts: [String] = []
        if n.sessions > 0 { parts.append(n.sessions == 1 ? "1 session" : "\(n.sessions) sessions") }
        if ReportValueWords.spent(n.cost.total) { parts.append(ReportValueWords.cost(n.cost.total)) }
        if ReportValueWords.spent(n.cost.waste) { parts.append("waste \(ReportValueWords.cost(n.cost.waste))") }
        if let lead = n.leadTimeSeconds { parts.append("lead time \(leadWords(lead))") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    public static let forgeTitle = ["github": "GitHub", "gitlab": "GitLab", "linear": "Linear", "jira": "Jira"]

    /// A forge that could not be read: "GitHub on Studio: not connected".
    public static func errorWords(_ e: DaemonAPI.ForgeListError, machine: String?) -> String {
        "\(forgeTitle[e.forge] ?? e.forge)\(machine.map { " on \($0)" } ?? ""): \(e.message)"
    }

    /// "Open on GitHub", by the ref's forge.
    public static func openOnWords(_ ref: String) -> String {
        let forge = ref.split(separator: ":", maxSplits: 1).first.map(String.init) ?? ""
        return "Open on \(forgeTitle[forge] ?? "the forge")"
    }

    /// A label's colour (#2956) as red, green and blue from 0 to 1; nil when the forge gave none.
    public static func rgb(_ color: String?) -> (r: Double, g: Double, b: Double)? {
        guard let color else { return nil }
        let hex = color.hasPrefix("#") ? String(color.dropFirst()) : color
        guard hex.count == 6, let v = Int(hex, radix: 16) else { return nil }
        return (Double((v >> 16) & 255) / 255, Double((v >> 8) & 255) / 255, Double(v & 255) / 255)
    }

    /// Whether dark text reads on a label's colour: light colours take dark text.
    public static func isLight(_ color: String?) -> Bool {
        guard let c = rgb(color) else { return true }
        return 0.299 * c.r + 0.587 * c.g + 0.114 * c.b > 0.6
    }

    public static let noAgentYet = "No agent yet"
    public static func noWork(_ kind: Kind) -> String {
        switch kind {
        case .milestone: "No milestones that an agent worked on yet."
        case .release: "No releases that an agent worked on yet."
        default: "No \(kind.title.lowercased()) match."
        }
    }
    public static let lineageOnlyNote = "Lineage lists a milestone or a release once an agent works on one of its issues or pull requests."
    public static let noForgeHere = "No machine reads issues and pull requests yet. Update Agents on a machine to see them."

    // The page of one issue, PR, milestone or release (#3119): its links grouped by relation, its
    // checks, its review and its cost.

    /// A relation's heading from this node's side: a PR "Fixes" an issue, the issue is "Fixed by" the PR.
    static let relWords: [String: (from: String, to: String)] = [
        "works-on": ("Works on", "Worked on by"), "opens": ("Opens", "Opened by"), "fixes": ("Fixes", "Fixed by"),
        "started": ("Started", "Started by"), "reviews": ("Reviews", "Reviewed by"), "closes": ("Closes", "Closed by"),
        "part-of": ("Part of", "Parts"),
    ]
    static let relOrder = ["Fixes", "Fixed by", "Closes", "Closed by", "Part of", "Parts", "Opens", "Opened by", "Reviews",
                           "Reviewed by", "Works on", "Worked on by", "Started", "Started by"]

    public struct LinkGroup: Sendable, Hashable {
        public var title: String
        public var rows: [(node: DaemonAPI.LineageNode, ended: Bool)]

        public static func == (a: Self, b: Self) -> Bool {
            a.title == b.title && a.rows.map(\.node) == b.rows.map(\.node) && a.rows.map(\.ended) == b.rows.map(\.ended)
        }

        public func hash(into h: inout Hasher) {
            h.combine(title)
            for r in rows { h.combine(r.node); h.combine(r.ended) }
        }
    }

    /// The node's links by relation, each other node once a group (an active link over an ended
    /// one), the groups in a fixed order and any relation not known after them.
    public static func linkGroups(_ here: DaemonAPI.LineageNode, _ links: [DaemonAPI.LineageLink]) -> [LinkGroup] {
        var groups: [String: [(node: DaemonAPI.LineageNode, ended: Bool)]] = [:]
        for l in links {
            let fromHere = l.from == here, toHere = l.to == here
            guard fromHere != toHere else { continue }
            let verb = l.rel.replacingOccurrences(of: "-", with: " ")
            let words = relWords[l.rel] ?? (verb, "\(verb) by")
            let title = fromHere ? words.from : words.to
            let other = fromHere ? l.to : l.from
            let ended = l.endedAt != nil
            var rows = groups[title] ?? []
            if let i = rows.firstIndex(where: { $0.node.ref == other.ref }) {
                if rows[i].ended && !ended { rows[i].ended = false }
            } else {
                rows.append((other, ended))
            }
            groups[title] = rows
        }
        let rank = { (t: String) in relOrder.firstIndex(of: t) ?? relOrder.count }
        return groups.sorted { rank($0.key) != rank($1.key) ? rank($0.key) < rank($1.key) : $0.key < $1.key }
            .map { LinkGroup(title: $0.key, rows: $0.value) }
    }

    /// The Work list a node's page is in: an issue, a PR, a milestone or a release; nil for any other.
    public static func kind(of node: DaemonAPI.LineageNode) -> Kind? { Kind(rawValue: node.kind) }

    /// A PR's checks: "Checks: 14 passing, 1 failing"; nil with none.
    public static func checksWords(_ checks: [DaemonAPI.ForgeCheck]?, summary: String? = nil) -> String? {
        guard let checks, !checks.isEmpty else {
            guard let summary, summary != "none" else { return nil }
            return "Checks \(summary)"
        }
        let parts = ["passing", "failing", "running", "skipped"].compactMap { state -> String? in
            let n = checks.filter { $0.state == state }.count
            return n > 0 ? "\(n) \(state)" : nil
        }
        return "Checks: \(parts.joined(separator: ", "))"
    }

    public static func reviewWords(_ review: String?) -> String? {
        guard let review else { return nil }
        let title = ["approved": "Approved", "changes_requested": "Changes requested", "review_required": "Review required"]
        return "Review: \(title[review] ?? review.replacingOccurrences(of: "_", with: " "))"
    }

    /// A page's cost: "Own $1.20 · total $3.40 · waste $0.30 · 2 failed checks"; nil with nothing banked.
    public static func pageCostWords(_ r: DaemonAPI.LineageCostRollup) -> String? {
        guard ReportValueWords.spent(r.total) || r.failedChecks > 0 else { return nil }
        var parts = ["Own \(ReportValueWords.cost(r.own))", "total \(ReportValueWords.cost(r.total))"]
        if ReportValueWords.spent(r.waste) { parts.append("waste \(ReportValueWords.cost(r.waste))") }
        if r.failedChecks > 0 { parts.append(r.failedChecks == 1 ? "1 failed check" : "\(r.failedChecks) failed checks") }
        return parts.joined(separator: " · ")
    }

    /// "by alexec · assigned to bob · milestone 0.14".
    public static func peopleWords(_ item: DaemonAPI.ForgeItem) -> String {
        var parts: [String] = []
        if let author = item.author { parts.append("by \(author)") }
        if !item.assignees.isEmpty { parts.append("assigned to \(item.assignees.joined(separator: ", "))") }
        if let milestone = item.milestone { parts.append("milestone \(milestone)") }
        return parts.joined(separator: " · ")
    }

    public static let noAgentOnIt = "No agent has worked on this yet."
    public static let notReadHere = "No machine could read this from its forge."
}

/// A place in Work (#3119): a list, or the page of one item by its ref, as the web page's
/// `#/work/<kind>` and `#/work/<kind>/<ref>`. Back and Forward go along them.
public struct WorkPlace: Hashable, Sendable {
    public var kind: WorkList.Kind
    public var ref: String?

    public init(kind: WorkList.Kind, ref: String? = nil) {
        self.kind = kind
        self.ref = ref
    }

    public var node: DaemonAPI.LineageNode? { ref.map { DaemonAPI.LineageNode(kind: kind.rawValue, ref: $0) } }
}
