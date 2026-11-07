import Foundation

/// Work ▸ Features (#3269, spec 3265), as the web page's `model/workFeatures.ts`: each `feature:`
/// label (`forge/features`) with its epic counts; opened, its open epics, each with its progress
/// and its lead, and its loose issues (the open issues with the label and no parent epic).
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

    /// The features as the list shows them (#3741): those with open work at the top, in their
    /// order, and the finished ones in the Finished group at the bottom.
    public static func groups(_ features: [DaemonAPI.ForgeFeature])
        -> (active: [DaemonAPI.ForgeFeature], finished: [DaemonAPI.ForgeFeature]) {
        (features.filter { !isFinished($0) }, features.filter(isFinished))
    }

    /// The Finished group's head: "Finished (7)".
    public static func finishedWords(_ count: Int) -> String { "Finished (\(count))" }

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
                by[key] = had
            } else {
                by[key] = f
                order.append(key)
            }
        }
        return order.compactMap { by[$0] }.sorted { $0.name.lowercased() < $1.name.lowercased() }
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

    /// An epic's progress: "1/6", its closed sub-issues of all; "0/0" with none yet.
    public static func progressWords(_ item: DaemonAPI.ForgeItem) -> String {
        "\(item.progress?.done ?? 0)/\(item.progress?.total ?? 0)"
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

    /// An epic's lead on its row: "● lead running", "● lead needs you", "lead stopped"; "—" with none.
    public static func leadWords(_ state: AgentState?) -> String {
        switch state {
        case nil, .archived: return "—"
        case .waitingOnUser: return "● lead needs you"
        case .starting, .running: return "● lead running"
        case .finished: return "lead waiting"
        case .stopped: return "lead stopped"
        case .queued: return "lead queued"
        }
    }

    /// When no feature is on any epic yet.
    public static let noFeatures = "No features yet. A feature is a feature:<name> label on an epic."
    /// An opened feature with no open epics or loose issues.
    public static let nothingOpen = "No open epics or issues."
}
