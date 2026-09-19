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

    /// What the runtime last said it offers, kept on the record so the controls
    /// around the prompt are the same ones whether the agent is running or was
    /// stopped a week ago. A finished agent has no process to ask.
    public var advertisedOptions: [ConfigOption]

    /// What the runtime says it takes after a slash. Kept for the same reason as the
    /// options: a finished agent has no process to ask.
    public var availableCommands: [SlashCommand]

    public var createdAt: Date
    public var lastActivityAt: Date
    public var endedReason: EndedReason?
    public var archivedReason: ArchivedReason?

    /// Only `byUser` exists in this feature: nothing archives itself.
    public enum ArchivedReason: String, Codable, Hashable, Sendable {
        case byUser
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        runtimeID = try c.decode(String.self, forKey: .runtimeID)
        cwd = try c.decode(URL.self, forKey: .cwd)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        state = try c.decode(AgentState.self, forKey: .state)
        runtimeSessionID = try c.decodeIfPresent(String.self, forKey: .runtimeSessionID)
        startOptions = try c.decodeIfPresent(StartOptions.self, forKey: .startOptions) ?? .none
        // Records written before the controls moved onto the prompt bar have none.
        advertisedOptions = try c.decodeIfPresent([ConfigOption].self, forKey: .advertisedOptions) ?? []
        availableCommands = try c.decodeIfPresent([SlashCommand].self, forKey: .availableCommands) ?? []
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        lastActivityAt = try c.decode(Date.self, forKey: .lastActivityAt)
        endedReason = try c.decodeIfPresent(EndedReason.self, forKey: .endedReason)
        archivedReason = try c.decodeIfPresent(ArchivedReason.self, forKey: .archivedReason)
    }

    public init(id: UUID = UUID(),
                runtimeID: String,
                cwd: URL,
                title: String? = nil,
                state: AgentState = .stopped,
                runtimeSessionID: String? = nil,
                startOptions: StartOptions = .none,
                advertisedOptions: [ConfigOption] = [],
                availableCommands: [SlashCommand] = [],
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
        self.advertisedOptions = advertisedOptions
        self.availableCommands = availableCommands
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
