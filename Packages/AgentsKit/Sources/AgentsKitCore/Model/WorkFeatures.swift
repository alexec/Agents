import Foundation

/// Work ▸ Features (#3269, spec 3265), as the web page's `model/workFeatures.ts`: each `feature:`
/// label (`forge/features`) with its epic counts, in the groups of `Group` (#4115); opened, its
/// open epics, each with its progress and its lead, and its loose issues (the open issues with the
/// label and no parent epic).
public enum WorkFeatures {
    /// A feature's name as a title: work is Work.
    public static func title(_ name: String) -> String {
        guard let first = name.first else { return name }
        return first.uppercased() + name.dropFirst()
    }

    /// A feature's counts: "3 epics · 2 open", and "· 4 open issues" when it has open issues
    /// that are not epics (#3741).
    public static func countWords(_ feature: DaemonAPI.ForgeFeature) -> String {
        let epics = "\(feature.epics) \(feature.epics == 1 ? "epic" : "epics") · \(feature.open) open"
        guard let issues = feature.issues, issues > 0 else { return epics }
        return epics + " · \(issues) open \(issues == 1 ? "issue" : "issues")"
    }

    /// A feature with no open epic and no open issue (#3741). A daemon that does not count the
    /// issues says nothing, so none of its features is finished.
    public static func isFinished(_ feature: DaemonAPI.ForgeFeature) -> Bool {
        feature.open == 0 && feature.issues == 0
    }

    /// The groups of the list, from the top (#4115): each feature is in the first one it matches.
    public enum Group: CaseIterable, Sendable {
        /// A session on its work waits for Alex, a pull request waits for Alex's approval, or an
        /// issue is labelled alex-todo.
        case needsYou
        /// A session that is not archived is labelled with one of its open issues or epics.
        case inFlight
        /// Open work and no session on it.
        case idle
        /// No open epic and no open issue (#3741).
        case finished

        /// The group's head: "Needs you", "Finished"; its count follows it in the tertiary colour (#4416).
        public var words: String {
            switch self {
            case .needsYou: return "Needs you"
            case .inFlight: return "In flight"
            case .idle: return "Idle"
            case .finished: return "Finished"
            }
        }
    }

    /// The features in their groups, as the list shows them (#4115): Needs you, In flight and Idle
    /// in their order, Idle the least recently updated first, and Finished at the bottom.
    public static func groups(_ features: [DaemonAPI.ForgeFeature], agents: [Agent] = [], approvals: [String] = [])
        -> [(group: Group, features: [DaemonAPI.ForgeFeature])] {
        let waiting = Set(approvals.map { "P" + WorkList.shortRef($0) })
        var by: [Group: [DaemonAPI.ForgeFeature]] = [:]
        for f in features {
            by[group(f, sessions: sessions(of: f, in: agents), approvals: waiting), default: []].append(f)
        }
        by[.idle]?.sort { ($0.updatedAt ?? .distantPast) < ($1.updatedAt ?? .distantPast) }
        return Group.allCases.compactMap { g in by[g].map { (g, $0) } }
    }

    private static func group(_ f: DaemonAPI.ForgeFeature, sessions: [Agent], approvals: Set<String>) -> Group {
        if isFinished(f) { return .finished }
        if !(f.waiting ?? []).isEmpty || sessions.contains(where: { a in
            a.state == .waitingOnUser || a.labels.contains { approvals.contains($0.value) }
        }) { return .needsYou }
        return sessions.isEmpty ? .idle : .inFlight
    }

    /// The sessions on a feature's work (#4115), of those this app knows: not archived, and
    /// labelled with the short ref of one of its open issues or epics (#3265, or ENG-5), as a lane
    /// and a lead label theirs.
    public static func sessions(of feature: DaemonAPI.ForgeFeature, in agents: [Agent]) -> [Agent] {
        let refs = Set((feature.refs ?? []).map(WorkList.shortRef))
        guard !refs.isEmpty else { return [] }
        return agents.filter { a in a.state != .archived && a.labels.contains { refs.contains($0.value) } }
    }

    /// An In flight feature's sessions: "1 session", "3 sessions".
    public static func sessionWords(_ count: Int) -> String { "\(count) \(count == 1 ? "session" : "sessions")" }

    /// A feature's bar (epic.md, Features note 2): its epics closed, of all; nil with no epic.
    public static func epicsDone(_ feature: DaemonAPI.ForgeFeature) -> Double? {
        feature.epics > 0 ? Double(max(feature.epics - feature.open, 0)) / Double(feature.epics) : nil
    }

    /// The words at a feature's bar: "1 of 2 epics done", "0 of 1 epic done".
    public static func epicsDoneWords(_ feature: DaemonAPI.ForgeFeature) -> String {
        "\(max(feature.epics - feature.open, 0)) of \(feature.epics) \(feature.epics == 1 ? "epic" : "epics") done"
    }

    /// What waits for the person on a Needs you feature (Features note 2): "P#4405 waits for your
    /// approval", "#4290 waits for you", "“Work look: epic page” needs you"; nil with nothing.
    public static func needsWords(_ feature: DaemonAPI.ForgeFeature, sessions: [Agent], approvals: [String]) -> String? {
        let waiting = approvals.map { "P" + WorkList.shortRef($0) }
        if let pr = waiting.first(where: { p in sessions.contains { $0.labels.contains { $0.value == p } } }) {
            return "\(pr) waits for your approval"
        }
        if let ref = feature.waiting?.first { return "\(WorkList.shortRef(ref)) waits for you" }
        if let session = sessions.first(where: { $0.state == .waitingOnUser }) {
            return session.title.map { "“\($0)” needs you" } ?? "A session needs you"
        }
        return nil
    }

    /// The features of several machines as one list, by name: the counts of one feature added up.
    /// Its issues are unknown when one machine does not count them.
    public static func merge(_ lists: [[DaemonAPI.ForgeFeature]]) -> [DaemonAPI.ForgeFeature] {
        var by: [String: DaemonAPI.ForgeFeature] = [:]
        var order: [String] = []
        for f in lists.joined() {
            let key = f.name.lowercased()
            if var had = by[key] {
                had.epics += f.epics
                had.open += f.open
                had.issues = had.issues.flatMap { mine in f.issues.map { mine + $0 } }
                had.color = had.color ?? f.color
                had.refs = union(had.refs, f.refs)
                had.waiting = union(had.waiting, f.waiting)
                had.updatedAt = [had.updatedAt, f.updatedAt].compactMap(\.self).max()
                by[key] = had
            } else {
                by[key] = f
                order.append(key)
            }
        }
        return order.compactMap { by[$0] }.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    private static func union(_ a: [String]?, _ b: [String]?) -> [String]? {
        guard let a else { return b }
        guard let b else { return a }
        return a + b.filter { !a.contains($0) }
    }

    /// An opened feature: its open epics and its loose issues, each once, the last updated first.
    public struct Opened: Equatable, Sendable {
        public var epics: [DaemonAPI.ForgeItem]
        public var loose: [DaemonAPI.ForgeItem]
    }

    /// The open issues with a feature's label, read from `forge/issues`, as the feature shows them:
    /// the epics, and the issues with no parent that are not epics. A child of an epic is in its plan.
    public static func opened(_ items: [DaemonAPI.ForgeItem]) -> Opened {
        var seen = Set<String>()
        let mine = items.filter { $0.node.kind == "issue" && $0.state == "open" && seen.insert($0.node.ref).inserted }
            .sorted { $0.updatedAt > $1.updatedAt }
        return Opened(epics: mine.filter(isEpic), loose: mine.filter { !isEpic($0) && $0.parent == nil })
    }

    /// An epic: labelled epic, or the parent of sub-issues.
    public static func isEpic(_ item: DaemonAPI.ForgeItem) -> Bool {
        item.level == "epic" || (item.progress?.total ?? 0) > 0
    }

    /// An epic's progress: "1 of 6", its closed sub-issues of all; "0 of 0" with none yet.
    public static func progressWords(_ item: DaemonAPI.ForgeItem) -> String {
        "\(item.progress?.done ?? 0) of \(item.progress?.total ?? 0)"
    }

    /// The session that leads an epic, of those this app knows: labelled lead and the epic's short
    /// ref (#3265, or ENG-5 on Linear), as Start lead labels it; not archived; a live one first,
    /// then the newest.
    public static func lead(of epic: DaemonAPI.LineageNode, in agents: [Agent]) -> Agent? {
        let ref = WorkList.shortRef(epic.ref)
        return agents.filter { a in
            a.state != .archived && a.labels.contains { $0.value == "lead" } && a.labels.contains { $0.value == ref }
        }.max { a, b in
            a.state.holdsRuntime != b.state.holdsRuntime ? b.state.holdsRuntime : a.createdAt < b.createdAt
        }
    }

    /// An epic's lead on its row: "● lead working", "● lead needs you", "lead stopped"; "—" with none.
    public static func leadWords(_ state: AgentState?) -> String {
        switch state {
        case nil, .archived: return "—"
        case .waitingOnUser: return "● lead needs you"
        case .starting, .running: return "● lead working"
        case .finished: return "lead waiting"
        case .stopped: return "lead stopped"
        case .queued: return "lead queued"
        }
    }

    /// When no feature is on any epic yet (states board, 10): the title, then two lines.
    public static let noFeaturesTitle = "No features yet"
    public static let noFeatures = "A feature is a feature:<name> label on an epic."
    public static let noFeaturesLabel = "Label an epic on its forge to see it here."
    /// An opened feature with no open epics or loose issues.
    public static let nothingOpen = "No open epics or issues."
}
