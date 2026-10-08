import Foundation

/// Which session in the caller's project a value names, and the list of them (065).
///
/// Decided here, once, so `list_sessions`, `read_session` and their tests share every
/// sentence. The project is the caller's own and is never a parameter an agent can set.
public enum SessionLookup {
    public enum Found: Sendable {
        case session(Agent)
        case refused(String)
    }

    public static let noValue = "Give a session id or exact title."
    public static let unavailable = "That conversation's history is unavailable."

    public static func missing(_ value: String) -> String {
        "There is no session named \u{201C}\(value)\u{201D} in this project."
    }

    /// The live sessions in `project`, archived ones included, newest activity first and
    /// ids ascending among equals.
    public static func sessions(in project: URL, agents: some Sequence<Agent>) -> [Agent] {
        let project = Project.standardize(project)
        return agents.filter { $0.projectFolder == project }.sorted {
            $0.lastActivityAt != $1.lastActivityAt
                ? $0.lastActivityAt > $1.lastActivityAt
                : $0.id.uuidString < $1.id.uuidString
        }
    }

    /// An id before a title; nothing from another project, not even that it exists. A
    /// deleted session is not found, like one that never was (#398).
    public static func find(_ value: String, in project: URL, agents: some Sequence<Agent>) -> Found {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return .refused(noValue) }
        let live = sessions(in: project, agents: agents)
        if let id = UUID(uuidString: value), let agent = live.first(where: { $0.id == id }) {
            return .session(agent)
        }
        let titled = live.filter { $0.title == value }
        if titled.count == 1 { return .session(titled[0]) }
        if titled.count > 1 {
            let matches = titled.map { "\($0.id.uuidString) — \(PoolWords.runtimeName($0.runtimeID)), "
                + "\(status(of: $0)), \(when($0.lastActivityAt))" }
            return .refused("More than one session is named \u{201C}\(value)\u{201D}: "
                            + matches.joined(separator: "; ") + ". Read one by id.")
        }
        return .refused(missing(value))
    }

    /// How many sessions a page of `list_sessions` gives when not asked, and the most it
    /// gives when asked (#210): a project keeps hundreds, each line with its last report,
    /// and all of them went into the calling agent's context.
    public static let pageSize = 30
    public static let largestPage = 100

    /// What `list_sessions` says: a line for each session on the page, the caller's
    /// marked. Its worktree and the resources it holds are said too, so the clean-up
    /// workflow (#199) can tell whose build output a folder is and leave a working or
    /// leasing one alone. The ones not archived come first; the page ends with how many
    /// follow and the `after` that gives them.
    public static func list(in project: URL, agents: some Sequence<Agent>, caller: UUID?,
                            holding: [UUID: [String]] = [:], limit: Int? = nil,
                            after: String? = nil) -> String {
        let size = min(max(1, limit ?? pageSize), largestPage)
        let sorted = sessions(in: project, agents: agents)
        guard !sorted.isEmpty else { return "There are no sessions in this project." }
        let all = sorted.filter { $0.state != .archived } + sorted.filter { $0.state == .archived }
        var from = 0
        if let after {
            guard let at = all.firstIndex(where: { $0.id.uuidString == after.uppercased() }) else {
                return "No session in this project has the id \u{201C}\(after)\u{201D} any more. "
                    + "Call list_sessions without `after` to start again."
            }
            from = at + 1
        }
        let page = all[from..<min(from + size, all.count)]
        guard !page.isEmpty else { return "There are no more sessions in this project." }
        let lines = page.map { agent -> String in
            let name = (agent.title.map { "\u{201C}\($0)\u{201D}" } ?? "Untitled") + (agent.id == caller ? " (you)" : "")
            var line = "- \(agent.id.uuidString): \(name) — \(PoolWords.runtimeName(agent.runtimeID)), "
                + "\(status(of: agent)), last active \(when(agent.lastActivityAt))."
            if let worktree = agent.worktree {
                line += " Worktree: \(worktree.root.path)" + (worktree.branch.map { " on \($0)" } ?? "") + "."
            }
            if let held = holding[agent.id], !held.isEmpty {
                line += " Holding: " + held.joined(separator: ", ") + "."
            }
            if let said = agent.report?.message { line += " Last said: \(said)" }
            line += labels(of: agent)
            return line
        }
        var text = (["Sessions in this project, not archived first, most recent first. "
                     + "Read one with read_session, by id or exact title."]
                    + lines).joined(separator: "\n")
        let rest = all[page.endIndex...]
        if let last = page.last, !rest.isEmpty {
            let archived = rest.filter { $0.state == .archived }.count
            text += "\n\n\(rest.count) more"
                + (archived == 0 ? "" : archived == rest.count ? ", all archived" : ", \(archived) of them archived")
                + ". For the next page, call list_sessions with after: \"\(last.id.uuidString)\"."
        }
        return text
    }

    public static func labels(of agent: Agent) -> String {
        guard !agent.labels.isEmpty else { return "" }
        return " Labels: " + agent.labels.map { "\($0.value) (\($0.owner.rawValue))" }
            .joined(separator: ", ") + "."
    }

    /// The status in the agent list's words: the group, and why it stopped when it did.
    public static func status(of agent: Agent) -> String {
        let group = agent.group(wantsEyes: false).title
        guard agent.state == .stopped, let why = agent.endedReason?.summary else { return group }
        return "\(group): \(why)"
    }

    static func when(_ date: Date) -> String {
        date.formatted(.iso8601)
    }
}
