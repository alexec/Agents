import Foundation

/// Work (#3119, spec 3100): every issue and pull request across the person's folders and forges,
/// from `forge/issues` and `forge/pulls` on each machine, one row per ref, with what lineage knows
/// about it (`reports/nodes`: cost, sessions, lead time) on top. Releases come from
/// `reports/nodes` alone in v1. The web page's `model/work.ts` is the same.
public enum WorkList {
    /// Work's lists, in the order of its tabs, by the lineage kind each holds.
    public enum Kind: String, CaseIterable, Identifiable, Sendable, Hashable, Codable {
        /// Features (#3269) are the `feature:` labels on the epics, not a lineage kind: an epic opens as an issue.
        /// Timeline (#4173) is the epics on a time axis, the Mac's alone for now (`WorkTimeline`).
        case issue, pr, feature, release, timeline

        public var id: Self { self }

        public var title: String {
            switch self {
            case .issue: "Issues"
            case .pr: "Pull requests"
            case .feature: "Features"
            case .release: "Releases"
            case .timeline: "Timeline"
            }
        }

        /// Issues and PRs are read from the forges; releases from lineage alone;
        /// features from the forges' labels, as a list of their own.
        public var fromForge: Bool { self == .issue || self == .pr }

        /// The states a list can be narrowed to: a PR's merged is its own.
        public var states: [State] { self == .pr ? [.open, .merged, .closed, .all] : [.open, .closed, .all] }

        /// A release's Newest is its version, the highest first (#4421).
        public var sorts: [Sort] { fromForge ? Sort.allCases : self == .release ? [.newest, .cost] : [.updated, .cost] }

        /// The sort a list opens with: a release's is Newest.
        public var defaultSort: Sort { self == .release ? .newest : .updated }
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
        /// Why a closed issue closed (completed, not_planned or duplicate), where the forge says it (#4365).
        public var stateReason: String?
        /// The tracker's own name for its step (a Jira status, #3260), shown in place of `state`.
        public var status: String?
        public var labels: [DaemonAPI.ForgeLabel]
        /// The ref's repo or tracker: github:alexec/Agents, linear:ENG (a Linear team, #3311), jira.
        public var repo: String
        public var author: String?
        /// The author's picture, a URL that only `forge/image` reads (#4363).
        public var avatar: String?
        public var assignees: [String]
        public var updated: Date
        /// When it opened, and when it closed or merged, where the forge says them (#4373).
        public var created: Date?
        public var closed: Date?
        public var url: URL?
        /// The machine the forge read came from, to read the item again on.
        public var host: MachineRef?
        /// The folder on `host` the forge read was for (#3283): its project is the row's.
        public var folder: String?
        public var draft: Bool
        public var lineage: DaemonAPI.ReportNode?
        /// How many comments it has (0 when the forge did not say), and a pull request's checks
        /// and review (#4391), for the row's trailing edge.
        public var comments: Int
        public var checks: String?
        public var review: String?

        public var id: String { node.ref }

        public init(node: DaemonAPI.LineageNode, title: String, state: String, labels: [DaemonAPI.ForgeLabel] = [],
                    repo: String, author: String? = nil, assignees: [String] = [],
                    updated: Date, url: URL? = nil, host: MachineRef? = nil, folder: String? = nil, draft: Bool = false,
                    lineage: DaemonAPI.ReportNode? = nil, status: String? = nil, comments: Int = 0, checks: String? = nil,
                    review: String? = nil, stateReason: String? = nil, avatar: String? = nil, created: Date? = nil,
                    closed: Date? = nil) {
            self.node = node
            self.title = title
            self.state = state
            self.stateReason = stateReason
            self.status = status
            self.labels = labels
            self.repo = repo
            self.author = author
            self.avatar = avatar
            self.assignees = assignees
            self.updated = updated
            self.created = created
            self.closed = closed
            self.url = url
            self.host = host
            self.folder = folder
            self.draft = draft
            self.lineage = lineage
            self.comments = comments
            self.checks = checks
            self.review = review
        }

        /// A row from the forge's item, with its lineage when there is any.
        public init(_ item: DaemonAPI.ForgeItem, on host: MachineRef, lineage: DaemonAPI.ReportNode? = nil) {
            self.init(node: item.node, title: item.title, state: item.state, labels: item.labels, repo: WorkList.repo(of: item.node.ref),
                      author: item.author, assignees: item.assignees, updated: item.updatedAt,
                      url: item.url.flatMap(URL.init(string:)), host: host, folder: item.folder, draft: item.draft ?? false,
                      lineage: lineage,
                      status: item.status, comments: item.comments, checks: item.checks, review: item.review,
                      stateReason: item.stateReason, avatar: item.authorAvatar, created: item.createdAt, closed: item.closedAt)
        }

        /// A row lineage alone knows: a release, named by its tag until the forge names it (#4426).
        public init(_ n: DaemonAPI.ReportNode) {
            self.init(node: n.node,
                      title: n.resolved?.title ?? (n.node.kind == "release" ? WorkList.shortRef(n.node.ref) : ReportValueWords.name(n.node)),
                      state: n.resolved?.state ?? (n.outcome == "merged" ? "merged" : ""),
                      labels: (n.resolved?.labels ?? []).map { DaemonAPI.ForgeLabel(name: $0) },
                      repo: WorkList.repo(of: n), updated: n.lastAt,
                      url: WorkList.url(n.node), lineage: n)
        }
    }

    /// The repo or tracker of a ref: "github:alexec/Agents" of "github:alexec/Agents#12", the team "linear:ENG" of
    /// "linear:ENG-4" (#3311), "jira" of "jira:PROJ-1".
    public static func repo(of full: String) -> String {
        // Read in the old form (#4800): the words are made from it.
        let ref = WireRef.legacy(full)
        guard let colon = ref.firstIndex(of: ":") else { return ref }
        let forge = String(ref[..<colon])
        let id = ref[ref.index(after: colon)...]
        if forge == "linear" {
            guard id.wholeMatch(of: /[A-Z][A-Z0-9]*-\d+/) != nil, let dash = id.lastIndex(of: "-") else { return forge }
            return "linear:\(id[..<dash])"
        }
        if forge == "jira" { return forge }
        guard let cut = id.range(of: #"[#!]|/release/"#, options: .regularExpression) else { return ref }
        return "\(forge):\(id[..<cut.lowerBound])"
    }

    /// A lineage node's repo: lineage says "linear" for every Linear issue, Work its team (#3311).
    static func repo(of n: DaemonAPI.ReportNode) -> String {
        if let repo = n.repo.map(WireRef.legacy), repo != "linear" { return repo }
        return repo(of: n.node.ref)
    }

    /// Where a node is on its forge, as far as its ref says: a PR's is its /pull/ page.
    public static func url(_ node: DaemonAPI.LineageNode) -> URL? {
        ReportValueWords.url(node).map { LineageList.pullRequest(node, $0) }
    }

    /// "alexec/Agents" of "github:alexec/Agents"; "Linear · ENG" of a Linear team (#3311); "Jira" of "jira";
    /// "Azure Boards · acme/web" of an Azure Boards project (#3815).
    public static func repoName(_ full: String) -> String {
        let repo = WireRef.legacy(full)
        if repo.hasPrefix("linear:") { return "Linear · \(repo.dropFirst("linear:".count))" }
        if repo.hasPrefix("azureboards:") { return "Azure Boards · \(repo.dropFirst("azureboards:".count))" }
        if let tracker = forgeTitle[repo], !repo.contains(":") { return tracker }
        return repo.replacingOccurrences(of: #"^[a-z][a-z0-9-]*:"#, with: "", options: .regularExpression)
    }

    /// An issue's or a PR's number in its repo, for Newest; 0 for one without.
    public static func number(_ full: String) -> Int {
        let ref = WireRef.legacy(full)
        guard let range = ref.range(of: #"[#!-]\d+$"#, options: .regularExpression) else { return 0 }
        return Int(ref[range].dropFirst()) ?? 0
    }

    /// "#12", "!45", "ENG-4" or "v0.14.0": a row's short name in its repo.
    public static func shortRef(_ full: String) -> String {
        let ref = WireRef.legacy(full)
        if let range = ref.range(of: #"[#!]\d+$"#, options: .regularExpression) { return String(ref[range]) }
        if let range = ref.range(of: #"/release/.+$"#, options: .regularExpression) {
            return String(ref[range].dropFirst("/release/".count))
        }
        return ReportValueWords.name(DaemonAPI.LineageNode(kind: "", ref: ref))
    }

    /// Whether a title says its short name already, as a release lineage could not resolve does.
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

    /// A project in Work's Project filter (#3283): New Session's (`NewSessionProject`), a folder that
    /// names none a project of its own, and its folders on each machine as `folderKey`s.
    public struct Project: Sendable, Hashable, Identifiable {
        public var id: String
        public var name: String
        public var folders: Set<String>

        public init(id: String, name: String, folders: Set<String>) {
            self.id = id
            self.name = name
            self.folders = folders
        }
    }

    /// The Project filter's first choice (#3283), as Work lists everything.
    public static let allProjects = "All projects"

    /// A folder as Work matches it to a forge item's (#3283): `host|path`, with no slash at the end.
    public static func folderKey(host: MachineRef, path: String) -> String {
        var path = path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return "\(host.rawValue)|\(path)"
    }

    /// Each project's repos and trackers (#3283): those of the items its folders read, on every
    /// machine, before the copies of one ref are merged, so a repo two projects read is in both.
    /// The projects in their order, without the ones whose folders read nothing.
    public static func projectRepos(_ projects: [Project], lists: [(host: MachineRef, items: [DaemonAPI.ForgeItem])])
        -> [(project: Project, repos: Set<String>)] {
        var read: [String: Set<String>] = [:]
        for (host, items) in lists {
            for item in items {
                guard let folder = item.folder else { continue }
                read[folderKey(host: host, path: folder), default: []].insert(repo(of: item.node.ref))
            }
        }
        return projects.compactMap { project in
            let repos = project.folders.reduce(into: Set<String>()) { $0.formUnion(read[$1] ?? []) }
            return repos.isEmpty ? nil : (project, repos)
        }
    }

    /// The project of the folder a forge item was read for on `host` (#3283), for its page; nil
    /// when the folder is in none of `projects`.
    public static func project(ofFolder folder: String?, on host: MachineRef, in projects: [Project]) -> Project? {
        guard let folder else { return nil }
        let key = folderKey(host: host, path: folder)
        return projects.first { $0.folders.contains(key) }
    }

    /// What a list is narrowed to. Empty project, repo, label, assignee or text is any. A board (#3282) is
    /// a board's url, which the machines narrow to as they read: it is not a filter of the rows.
    public struct Filter: Sendable, Hashable {
        public var state: State
        /// A `Project`'s id (#3283): the rows of the repos its folders read.
        public var project: String
        public var repo: String
        public var label: String
        public var assignee: String
        public var text: String
        public var board: String

        public init(state: State = .open, project: String = "", repo: String = "", label: String = "", assignee: String = "",
                    text: String = "", board: String = "") {
            self.state = state
            self.project = project
            self.repo = repo
            self.label = label
            self.assignee = assignee
            self.text = text
            self.board = board
        }
    }

    /// The boards of each machine (#3282), each once by url, in the order first given; the name
    /// a board first has is kept.
    public static func mergeBoards(_ lists: [[DaemonAPI.ProjectBoard]]) -> [DaemonAPI.ProjectBoard] {
        var seen = Set<String>()
        return lists.flatMap { $0 }.filter { seen.insert($0.url).inserted }
    }

    /// A board's name in the Board menu, from the boards read; the url when it is not one of them.
    public static func boardName(_ url: String, in boards: [DaemonAPI.ProjectBoard]) -> String {
        boards.first { $0.url == url }?.name ?? url
    }

    /// Whether a row is in the state asked: a merged PR is merged, not closed.
    public static func matches(_ row: Row, state: State) -> Bool {
        switch state {
        case .all: true
        case .closed: row.state == "closed" || (row.node.kind != "pr" && row.state == "merged")
        case .open, .merged: row.state == state.rawValue
        }
    }

    /// The rows `f` asks for. `projects` is `projectRepos`: a project picked that read nothing has no rows.
    public static func filter(_ rows: [Row], _ f: Filter, projects: [(project: Project, repos: Set<String>)] = []) -> [Row] {
        let words = f.text.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        let repos = f.project.isEmpty ? nil : projects.first { $0.project.id == f.project }?.repos ?? []
        return rows.filter { r in
            guard matches(r, state: f.state) else { return false }
            if let repos, !repos.contains(r.repo) { return false }
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
            // A forge numbers its items as they are made, so the highest number is the newest; a
            // release's version says it (#4421).
            return rows.sorted { a, b in
                if a.node.kind == "release", b.node.kind == "release" {
                    let (x, y) = (shortRef(a.node.ref), shortRef(b.node.ref))
                    if WorkReleaseLook.newer(x, than: y) { return true }
                    if WorkReleaseLook.newer(y, than: x) { return false }
                    return tie(a, b)
                }
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

    /// Where an item's page stands in the list it was opened from (#3257): the refs above and
    /// below it, and its place, counted from 1.
    public struct Neighbours: Sendable, Hashable {
        public var previous: String?
        public var next: String?
        public var position: Int
        public var count: Int
    }

    /// The item's neighbours in `rows`, the list as it is filtered and sorted; nil when the ref is not in it.
    public static func neighbours(of ref: String, in rows: [Row]) -> Neighbours? {
        guard let i = rows.firstIndex(where: { $0.node.ref == ref }) else { return nil }
        return Neighbours(previous: i > 0 ? rows[i - 1].node.ref : nil,
                          next: i + 1 < rows.count ? rows[i + 1].node.ref : nil,
                          position: i + 1, count: rows.count)
    }

    /// "3 of 42"; "3 of 42+" while the list has more pages to read.
    public static func positionWords(_ n: Neighbours, more: Bool) -> String {
        "\(n.position) of \(n.count)\(more ? "+" : "")"
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

    public static let forgeTitle = ["github": "GitHub", "gitlab": "GitLab", "linear": "Linear", "jira": "Jira",
                                    "azureboards": "Azure Boards", "forgejo": "Forgejo", "bitbucket": "Bitbucket",
                                    "azuredevops": "Azure DevOps"]

    /// A forge that could not be read: "GitHub on Studio: not connected".
    public static func errorWords(_ e: DaemonAPI.ForgeListError, machine: String?) -> String {
        "\(forgeTitle[e.forge] ?? e.forge)\(machine.map { " on \($0)" } ?? ""): \(e.message)"
    }

    /// "Open on GitHub", by the ref's forge.
    public static func openOnWords(_ ref: String) -> String { "Open on \(forgeName(ref))" }

    /// "GitHub" of "github:alexec/Agents#12", by the ref's forge; "the forge" of one it does not know.
    public static func forgeName(_ ref: String) -> String {
        let forge = WireRef.legacy(ref).split(separator: ":", maxSplits: 1).first.map(String.init) ?? ""
        return forgeTitle[forge] ?? "the forge"
    }

    /// The forges whose pull requests have no labels (#3881): Bitbucket's API has none.
    public static let forgesWithoutPRLabels: Set<String> = ["bitbucket"]

    /// Whether the item's page offers Labels: not on a pull request of a forge whose pull requests have none (#3881).
    public static func takesLabels(_ node: DaemonAPI.LineageNode) -> Bool {
        let forge = WireRef.legacy(node.ref).split(separator: ":", maxSplits: 1).first.map(String.init) ?? ""
        return !(node.kind == "pr" && forgesWithoutPRLabels.contains(forge))
    }

    /// Why a write failed, in the machine's own words: a JSON-RPC error's message, not Foundation's
    /// "The operation couldn't be completed".
    public static func failureWords(_ error: any Error) -> String {
        (error as? JSONRPCError)?.message ?? error.localizedDescription
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
    public static let lineageOnlyNote = "Lineage lists a release once an agent works on one of its issues or pull requests."
    public static let noForgeHere = "No machine reads issues and pull requests yet. Update Agents on a machine to see them."

    // The page of one issue, PR or release (#3119): its links grouped by relation, its
    // checks, its review and its cost.

    /// The Work list a node's page is in: an issue, a PR or a release; nil for any other.
    public static func kind(of node: DaemonAPI.LineageNode) -> Kind? {
        Kind(rawValue: node.kind).flatMap { $0 == .feature || $0 == .timeline ? nil : $0 }
    }

    // MARK: Actions (#3130)

    /// A merge method's button, as GitHub says it.
    public static func mergeTitle(_ method: DaemonAPI.ForgeMergeMethod) -> String {
        switch method {
        case .merge: "Create a merge commit"
        case .squash: "Squash and merge"
        case .rebase: "Rebase and merge"
        }
    }

    /// The merge button's own words: what its default method does, and "when checks pass" while
    /// some still run, as the merge then waits for them.
    public static func mergeButton(_ method: DaemonAPI.ForgeMergeMethod?, waits: Bool) -> String {
        (method.map(mergeTitle) ?? "Merge") + (waits ? " when checks pass" : "")
    }

    /// Whether a merge waits for checks still running: auto-merge, as the forge does it.
    public static func mergeWaits(_ detail: DaemonAPI.ForgeItemDetail) -> Bool {
        detail.item.checks == "running" || (detail.checks ?? []).contains { $0.state == "running" }
    }

    /// The failed checks, which Rerun runs again and whose logs a person reads.
    public static func failedChecks(_ detail: DaemonAPI.ForgeItemDetail) -> [DaemonAPI.ForgeCheck] {
        (detail.checks ?? []).filter { $0.state == "failing" }
    }

    /// What a write did, for the line under the actions.
    public static func doneWords(_ method: String, _ done: DaemonAPI.ForgeDone, reopened: Bool = false, moved: Bool = false) -> String {
        switch method {
        case DaemonAPI.Method.forgeClose where moved: "Status changed."
        case DaemonAPI.Method.forgeComment: "Commented."
        case DaemonAPI.Method.forgeLabel: "Labels changed."
        case DaemonAPI.Method.forgeMerge: done.auto == true ? "Auto-merge is on: it merges when its checks pass." : "Merged."
        case DaemonAPI.Method.forgeApprove: "Approved."
        case DaemonAPI.Method.forgeAddChild: "Child added."
        case DaemonAPI.Method.forgeBlockedBy: "Blocked by changed."
        case DaemonAPI.Method.forgeClose: reopened ? "Reopened." : "Closed."
        case DaemonAPI.Method.forgeRerun:
            done.reran.map { $0 == 1 ? "1 run started again." : "\($0) runs started again." } ?? "Started again."
        default: "Done."
        }
    }

    /// "by alexec · assigned to bob".
    public static func peopleWords(_ item: DaemonAPI.ForgeItem) -> String {
        var parts: [String] = []
        if let author = item.author { parts.append("by \(author)") }
        if !item.assignees.isEmpty { parts.append("assigned to \(item.assignees.joined(separator: ", "))") }
        return parts.joined(separator: " · ")
    }

    public static let notReadHere = "No machine could read this from its forge."
}

/// A place in Work (#3119): a list, or the page of one item by its ref, as the web page's
/// `#/work/<kind>` and `#/work/<kind>/<ref>`. Back and Forward go along them.
public struct WorkPlace: Hashable, Sendable {
    public var kind: WorkList.Kind
    public var ref: String?
    /// The page was opened from its kind's list (#3257), so it has Previous and Next through it.
    /// A page opened from a lineage link or an address has not.
    public var fromList: Bool

    public init(kind: WorkList.Kind, ref: String? = nil, fromList: Bool = false) {
        self.kind = kind
        self.ref = ref
        self.fromList = fromList && ref != nil
    }

    public var node: DaemonAPI.LineageNode? { ref.map { DaemonAPI.LineageNode(kind: kind.rawValue, ref: $0) } }
}
