import Foundation

/// A search for an epic, its sessions under a heading for each of its issues (#3900): the
/// epic's own (its lead) first, then each child issue's in the epic's order, as the hosts'
/// `lineage/sessions` said them. A session on two children is under the first one; one the
/// search found by its label or title alone is under the epic.
///
/// Only while a search names an epic: the sidebar's own layout stays one list (#495, #2381).
/// Worked out here for the Mac's window and the Remote; the web's `issueGroups` is the same.
public struct SidebarIssueGroup: Identifiable {
    public let issue: DaemonAPI.LineageSessionIssue
    /// The live sessions newest started first, then the archived newest archived first.
    public let sessions: [Agent]
    public var id: String { issue.node.ref }
    public var title: String { Self.title(of: issue) }

    /// `#3898 Session search: …`, or `#3898` while its title is not known.
    public static func title(of issue: DaemonAPI.LineageSessionIssue) -> String {
        let ref = issue.node.ref
        let number = ref.range(of: "#", options: .backwards).map { "#" + ref[$0.upperBound...] } ?? ref
        let title = issue.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? number : "\(number) \(title)"
    }

    /// Whether the search names an epic: an issue the hosts said has sub-issues.
    @MainActor
    public static func isOn(query: String, in work: AgentsModel) -> Bool {
        work.issueHeadings.count > 1 && SessionLabelQuery.issue(in: query) != nil
    }

    /// The sessions under their issues' headings, the headings with none left out.
    @MainActor
    public static func groups(_ agents: [Agent], in work: AgentsModel) -> [SidebarIssueGroup] {
        let headings = work.issueHeadings
        guard let epic = headings.first else { return [] }
        var under: [DaemonAPI.LineageNode: [Agent]] = [:]
        for agent in agents {
            let on = work.issueSessions[agent.id].flatMap { node in headings.contains { $0.node == node } ? node : nil }
            under[on ?? epic.node, default: []].append(agent)
        }
        return headings.compactMap { heading in
            guard let held = under[heading.node], !held.isEmpty else { return nil }
            let live = held.filter { $0.state != .archived }.sorted { $0.createdAt > $1.createdAt }
            let archived = held.filter { $0.state == .archived }.sorted { $0.archivedOrder > $1.archivedOrder }
            return SidebarIssueGroup(issue: heading, sessions: live + archived)
        }
    }
}
