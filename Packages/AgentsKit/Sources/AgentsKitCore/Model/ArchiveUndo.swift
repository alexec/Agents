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

    public init(id: UUID = UUID(), agentIDs: [UUID], title: String?, stopped: Bool) {
        self.id = id
        self.agentIDs = agentIDs
        self.title = Self.shown(title)
        self.stopped = stopped
    }

    /// How long Undo is offered.
    public static let seconds: Double = 5
    public static let undoLabel = "Undo"

    /// "Archived “Fix the parser”", and that it stays stopped when Archive stopped it.
    public var line: String { Self.line(title: title, stopped: stopped) }

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
