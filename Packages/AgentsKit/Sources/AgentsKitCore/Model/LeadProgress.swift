import Foundation

/// A lead's sidebar row (#3270, spec 3265): a session labelled `lead` that works on an epic shows
/// the epic's progress after its title, "Work pages lead · 5/7", as the web page's
/// `model/leadProgress.ts`. The epic is the issue the session works on (lineage, from its `#<n>`
/// label); the figures are its plan's children closed of all of them, as the Plan section's header.
public enum LeadProgress {
    /// The label that makes a session a lead (the `lead` skill's "Starting a lead").
    public static let label = "lead"

    /// Whether a session is a lead.
    public static func isLead(_ agent: Agent) -> Bool {
        agent.labels.contains { $0.value == label }
    }

    /// What a lead's progress is asked again at: its state and labels, which change each time it
    /// wakes for a child. Nil for a session that is not a lead.
    public static func turn(_ agent: Agent) -> String? {
        isLead(agent) ? "\(agent.state.rawValue)|\(agent.labels.map(\.value).joined(separator: ","))" : nil
    }

    /// The epic a session works on: the newest issue it is linked to by `works-on` that has not
    /// ended. Nil when it works on none.
    public static func epic(of session: UUID, in links: [DaemonAPI.LineageLink]) -> DaemonAPI.LineageNode? {
        // By the session's id: its ref's topic is its project's, which this app does not know (#4800).
        let mine = session.uuidString.uppercased()
        return links
            .filter { WireRef.sessionID(fromRef: $0.from.ref)?.uppercased() == mine && $0.rel == "works-on" && $0.to.kind == "issue" && $0.endedAt == nil }
            .max { $0.at < $1.at }?.to
    }

    /// "5/7": the plan's children closed, of all of them. Nil for a plan with no children.
    public static func words(_ plan: DaemonAPI.ForgePlan) -> String? {
        guard !plan.children.isEmpty else { return nil }
        let done = plan.children.filter { $0.item.state == "closed" }.count
        return "\(done)/\(plan.children.count)"
    }

    /// What a screen reader hears: "5 of 7 done".
    public static func spoken(_ words: String) -> String {
        let parts = words.split(separator: "/")
        guard parts.count == 2 else { return words }
        return "\(parts[0]) of \(parts[1]) done"
    }
}
