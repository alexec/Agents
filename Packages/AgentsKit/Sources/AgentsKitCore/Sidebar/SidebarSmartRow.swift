import Foundation

/// One of the rows at the top of the sidebar that gather sessions across every project
/// and host by what they want (#495): Needs You, Working, Unread — Things' Inbox and
/// Today, Mail's smart mailboxes.
///
/// Read off each project's shelf (#165), so a folded smart row costs a sum of counts per
/// project and not a pass over every agent held; only an open one lists its sessions.
public enum SidebarSmartRow: String, CaseIterable, Hashable, Sendable {
    case needsYou, working, unread

    public var title: String {
        switch self {
        case .needsYou: "Needs You"
        case .working: "Working"
        case .unread: "Unread"
        }
    }

    public var systemImage: String {
        switch self {
        case .needsYou: "exclamationmark.bubble"
        case .working: "circle.dotted"
        case .unread: "circle.inset.filled"
        }
    }

    /// Needs You starts open, so the first thing the window says is who is waiting;
    /// the others start folded, their counts in sight.
    public var startsOpen: Bool { self == .needsYou }

    /// How many sessions it gathers across the projects named.
    @MainActor
    public func count(in work: AgentsModel, projects: [ProjectKey]) -> Int {
        projects.reduce(0) { total, key in
            let shelf = work.shelf(key)
            switch self {
            case .needsYou: return total + (shelf.counts[.needsAttention] ?? 0) + (shelf.counts[.blocked] ?? 0)
            case .working: return total + (shelf.counts[.running] ?? 0)
            case .unread: return total + shelf.unread
            }
        }
    }

    /// The sessions it gathers, newest started first, as a search leaves them.
    @MainActor
    public func agents(in work: AgentsModel, projects: [ProjectKey], query: String = "") -> [Agent] {
        let words = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matcher = words.isEmpty ? nil : SessionLabelQuery(words)
        let gathered = projects.flatMap { key -> [Agent] in
            let shelf = work.shelf(key)
            switch self {
            case .needsYou: return (shelf.groups[.needsAttention] ?? []) + (shelf.groups[.blocked] ?? [])
            case .working: return shelf.groups[.running] ?? []
            case .unread: return AgentGroup.live.flatMap { shelf.groups[$0] ?? [] }.filter(\.showsUnread)
            }
        }
        let shown = matcher.map { gathered.filter($0.matches) } ?? gathered
        return shown.sorted { $0.createdAt > $1.createdAt }
    }
}
