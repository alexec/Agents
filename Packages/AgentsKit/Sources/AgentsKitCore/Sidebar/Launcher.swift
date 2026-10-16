import Foundation

/// The main window's style (#1090), Settings ▸ Sidebar ▸ Home window: the sidebar of every
/// project, or a small launcher of project cards with each project in a window of its own
/// (#1089). Some people work across many projects at once; some in one at a time.
///
/// A display choice, kept with the others on the host (#1033), so every client shows the same.
public enum HomeWindow: String, CaseIterable, Hashable, Sendable {
    case allProjects, launcher

    /// Where it is kept, in the host's map and in each client's mirror of it.
    public static let defaultsKey = DisplayPreference.homeWindow
    /// With nothing kept: the sidebar, as before.
    public static let initial = HomeWindow.allProjects

    public var title: String {
        switch self {
        case .allProjects: "All projects"
        case .launcher: "Launcher"
        }
    }

    /// What is kept, read back; anything else is the first state.
    public init(stored: String?) {
        self = stored.flatMap(HomeWindow.init(rawValue:)) ?? .initial
    }
}

/// What the launcher's cards say (#1090): one grey line per project, and how many across
/// every project need the person, for its first card.
public enum LauncherCard {
    /// "3 working · 1 needs you · 2 unread", each part only when there is some; "idle"
    /// when there is nothing going on.
    public static func line(working: Int, needsYou: Int, unread: Int) -> String {
        var parts: [String] = []
        if working > 0 { parts.append("\(working) working") }
        if needsYou > 0 { parts.append("\(needsYou) needs you") }
        if unread > 0 { parts.append("\(unread) unread") }
        return parts.isEmpty ? "idle" : parts.joined(separator: " · ")
    }

    /// A project's line, read off its shelf (#165): working, needing the person (asking,
    /// blocked, or an approval waiting), and unread.
    @MainActor
    public static func line(for key: ProjectKey, in work: AgentsModel) -> String {
        let shelf = work.shelf(key)
        let needs = (shelf.counts[.needsAttention] ?? 0) + (shelf.counts[.blocked] ?? 0)
            + SidebarSmartRow.ownApprovals(in: work, key).count
        return line(working: shelf.counts[.running] ?? 0, needsYou: needs, unread: shelf.unread)
    }

    /// The sessions across every project that need the person, for the first card: Needs
    /// You's, every group on, so a pinned one is here too.
    @MainActor
    public static func needingYou(in work: AgentsModel, projects: [ProjectKey]) -> [Agent] {
        projects.flatMap { key in
            let shelf = work.shelf(key)
            return (shelf.groups[.needsAttention] ?? []) + (shelf.groups[.blocked] ?? [])
        }
    }

    /// How many need the person across every project: their sessions and the approvals waiting.
    @MainActor
    public static func needsYouCount(in work: AgentsModel, projects: [ProjectKey]) -> Int {
        needingYou(in: work, projects: projects).count
            + projects.reduce(0) { $0 + SidebarSmartRow.ownApprovals(in: work, $1).count }
    }
}
