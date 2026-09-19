import Foundation

/// One conversation with one runtime in one folder, however many processes or runtime
/// sessions it takes.
///
/// The id is ours and never changes. The runtime's session id is a note kept against
/// it, because the protocol has no way to supply one and all three runtimes ignore one
/// offered. That indirection is what lets an agent survive its runtime losing a
/// session: a new session is filed against the same agent, and the user sees one agent
/// throughout.
public struct Agent: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var runtimeID: String
    public var cwd: URL
    public var title: String?
    public var state: AgentState
    public var runtimeSessionID: String?
    public var startOptions: StartOptions
    public var createdAt: Date
    public var lastActivityAt: Date
    public var endedReason: EndedReason?
    public var archivedReason: ArchivedReason?

    /// Only `byUser` exists in this feature: nothing archives itself.
    public enum ArchivedReason: String, Codable, Hashable, Sendable {
        case byUser
    }

    public init(id: UUID = UUID(),
                runtimeID: String,
                cwd: URL,
                title: String? = nil,
                state: AgentState = .stopped,
                runtimeSessionID: String? = nil,
                startOptions: StartOptions = .none,
                createdAt: Date = Date(),
                lastActivityAt: Date = Date(),
                endedReason: EndedReason? = nil,
                archivedReason: Agent.ArchivedReason? = nil) {
        self.id = id
        self.runtimeID = runtimeID
        self.cwd = cwd
        self.title = title
        self.state = state
        self.runtimeSessionID = runtimeSessionID
        self.startOptions = startOptions
        self.createdAt = createdAt
        self.lastActivityAt = lastActivityAt
        self.endedReason = endedReason
        self.archivedReason = archivedReason
    }

    /// What the list shows when the runtime has not named the session itself.
    public static func fallbackTitle(from instruction: String) -> String {
        let firstLine = instruction
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? "Untitled"
        return firstLine.count > 80 ? String(firstLine.prefix(79)) + "…" : firstLine
    }

    /// The invariants from the data model, in a form a test can assert.
    public var isConsistent: Bool {
        if state == .archived && archivedReason == nil { return false }
        if state == .stopped && endedReason == nil { return false }
        if state == .finished && endedReason != .endTurn { return false }
        return true
    }
}
