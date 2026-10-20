import Foundation

/// Undo after Archive (#1534): what one Archive put away — the session and the ones it
/// started — for a strip at the foot of the list that offers Undo for a few seconds. Undo is
/// Unarchive, which does not start a session again: one that Archive stopped stays stopped,
/// and the strip says so. The page has its own copy of the words (`undoLine` in
/// `Web/src/model/archiveWords.ts`), held to `Fixtures/web/archive/undo.json`.
public struct ArchiveUndo: Equatable, Sendable, Identifiable {
    /// Each Archive its own strip, so a second one starts its seconds again.
    public let id: UUID
    /// The session archived first, then the ones it started.
    public var agentIDs: [UUID]
    public var title: String
    /// Whether Archive stopped one of them that was working.
    public var stopped: Bool
    /// How many sessions the person archived: more than one is a ⌫ over a selection (#1664).
    /// The ones they started are in `agentIDs` but not in this count.
    public var sessions: Int
    /// The workflows archived on the same ⌫ (#1664). Undo brings them back too.
    public var workflows: [WorkflowSummary]

    public init(id: UUID = UUID(), agentIDs: [UUID], title: String?, stopped: Bool,
                sessions: Int = 1, workflows: [WorkflowSummary] = []) {
        self.id = id
        self.agentIDs = agentIDs
        self.title = Self.shown(title)
        self.stopped = stopped
        self.sessions = sessions
        self.workflows = workflows
    }

    /// How long Undo is offered.
    public static let seconds: Double = 5
    public static let undoLabel = "Undo"

    /// What VoiceOver says when the strip comes (#1676): the line, then that Undo is there.
    public var announcement: String {
        (line.hasSuffix(".") ? line : line + ".") + " " + Self.undoLabel
    }

    /// "Archived “Fix the parser”", and that it stays stopped when Archive stopped it.
    /// A selection is a count: "Archived 3 sessions and 1 workflow" (#1664).
    public var line: String {
        if sessions + workflows.count <= 1 { return Self.line(title: title, stopped: stopped) }
        return Self.line(sessions: sessions, workflows: workflows.count, stopped: stopped)
    }

    public static func line(sessions: Int, workflows: Int, stopped: Bool) -> String {
        let parts = [count(sessions, "session"), count(workflows, "workflow")].compactMap { $0 }
        let archived = "Archived " + parts.joined(separator: " and ")
        return stopped ? archived + ". Undo does not start the stopped ones again." : archived
    }

    private static func count(_ n: Int, _ noun: String) -> String? {
        n == 0 ? nil : "\(n) \(noun)\(n == 1 ? "" : "s")"
    }

    public static func line(title: String, stopped: Bool) -> String {
        stopped ? "Archived “\(title)” and stopped it. Undo does not start it again." : "Archived “\(title)”"
    }

    /// Whether Archive stops a session in this state: it was at work.
    public static func stops(_ state: AgentState) -> Bool {
        state == .running || state == .starting || state == .waitingOnUser
    }

    private static func shown(_ title: String?) -> String {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "Untitled" : trimmed
    }
}
