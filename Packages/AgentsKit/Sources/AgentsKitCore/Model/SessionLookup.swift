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
    public static let gone = "That conversation is gone."
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

    /// An id before a title; a live session before a retired one; nothing from another
    /// project, not even that it exists.
    public static func find(_ value: String, in project: URL, agents: some Sequence<Agent>,
                            retired: some Sequence<Tombstone>) -> Found {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return .refused(noValue) }
        let live = sessions(in: project, agents: agents)
        let standard = Project.standardize(project)
        let gone = retired.filter { Project.standardize($0.project) == standard }
        if let id = UUID(uuidString: value) {
            if let agent = live.first(where: { $0.id == id }) { return .session(agent) }
            if gone.contains(where: { $0.id == id }) { return .refused(Self.gone) }
        }
        let titled = live.filter { $0.title == value }
        if titled.count == 1 { return .session(titled[0]) }
        if titled.count > 1 {
            let matches = titled.map { "\($0.id.uuidString) — \(PoolWords.runtimeName($0.runtimeID)), "
                + "\(status(of: $0)), \(when($0.lastActivityAt))" }
            return .refused("More than one session is named \u{201C}\(value)\u{201D}: "
                            + matches.joined(separator: "; ") + ". Read one by id.")
        }
        if gone.contains(where: { $0.title == value }) { return .refused(Self.gone) }
        return .refused(missing(value))
    }

    /// What `list_sessions` says: a line for each session, the caller's marked.
    public static func list(in project: URL, agents: some Sequence<Agent>, caller: UUID?) -> String {
        let all = sessions(in: project, agents: agents)
        guard !all.isEmpty else { return "There are no sessions in this project." }
        let lines = all.map { agent -> String in
            let name = (agent.title.map { "\u{201C}\($0)\u{201D}" } ?? "Untitled") + (agent.id == caller ? " (you)" : "")
            var line = "- \(agent.id.uuidString): \(name) — \(PoolWords.runtimeName(agent.runtimeID)), "
                + "\(status(of: agent)), last active \(when(agent.lastActivityAt))."
            if let said = agent.report?.message { line += " Last said: \(said)" }
            line += labels(of: agent)
            return line
        }
        return (["Sessions in this project, most recent first. Read one with read_session, by id or exact title."]
                + lines).joined(separator: "\n")
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
