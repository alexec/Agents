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

    /// How full the context was when the runtime last said. Kept on the record so the
    /// meter is there when an agent is opened again rather than only while it works.
    public var usage: Usage?

    /// What the last turn consumed, and what this agent has cost so far, per currency.
    public var lastTurnUsage: TurnUsage?
    public var costToDate: [String: Decimal]

    /// What the agent said it was going to do. The current one is last.
    public var plans: [Plan]

    /// Folders beyond `cwd` that this agent may reach, where the runtime takes them.
    public var additionalDirectories: [URL]

    /// MCP servers attached to this agent, sent when its session is made.
    public var mcpServers: [MCPServer]

    public var createdAt: Date
    public var lastActivityAt: Date
    public var endedReason: EndedReason?
    public var archivedReason: ArchivedReason?

    /// Keys a newer version wrote that this one does not know. Kept so that opening a
    /// record in an older build and saving it does not quietly delete them.
    public var unknownFields: [String: JSONValue]

    /// Everywhere this agent may read and write: its folder, and any it was given.
    public var folderScope: FolderScope { FolderScope(folders: [cwd] + additionalDirectories) }

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
        // Every field below arrived with 003. A record written before it has none of
        // them, and must still open.
        usage = try c.decodeIfPresent(Usage.self, forKey: .usage)
        lastTurnUsage = try c.decodeIfPresent(TurnUsage.self, forKey: .lastTurnUsage)
        costToDate = try c.decodeIfPresent([String: Decimal].self, forKey: .costToDate) ?? [:]
        plans = try c.decodeIfPresent([Plan].self, forKey: .plans) ?? []
        additionalDirectories = try c.decodeIfPresent([URL].self, forKey: .additionalDirectories) ?? []
        mcpServers = try c.decodeIfPresent([MCPServer].self, forKey: .mcpServers) ?? []
        let known = Set(CodingKeys.allCases.map(\.stringValue))
        let whole = (try? JSONValue(from: decoder).objectValue) ?? [:]
        unknownFields = whole.filter { !known.contains($0.key) }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(runtimeID, forKey: .runtimeID)
        try c.encode(cwd, forKey: .cwd)
        try c.encodeIfPresent(title, forKey: .title)
        try c.encode(state, forKey: .state)
        try c.encodeIfPresent(runtimeSessionID, forKey: .runtimeSessionID)
        try c.encode(startOptions, forKey: .startOptions)
        try c.encode(advertisedOptions, forKey: .advertisedOptions)
        try c.encode(availableCommands, forKey: .availableCommands)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(lastActivityAt, forKey: .lastActivityAt)
        try c.encodeIfPresent(endedReason, forKey: .endedReason)
        try c.encodeIfPresent(archivedReason, forKey: .archivedReason)
        try c.encodeIfPresent(usage, forKey: .usage)
        try c.encodeIfPresent(lastTurnUsage, forKey: .lastTurnUsage)
        if !costToDate.isEmpty { try c.encode(costToDate, forKey: .costToDate) }
        if !plans.isEmpty { try c.encode(plans, forKey: .plans) }
        if !additionalDirectories.isEmpty {
            try c.encode(additionalDirectories, forKey: .additionalDirectories)
        }
        if !mcpServers.isEmpty { try c.encode(mcpServers, forKey: .mcpServers) }
        // Whatever a newer version wrote, written back out beside our own fields.
        if !unknownFields.isEmpty {
            var extra = encoder.container(keyedBy: AnyKey.self)
            for (key, value) in unknownFields {
                try extra.encode(value, forKey: AnyKey(stringValue: key))
            }
        }
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case id, runtimeID, cwd, title, state, runtimeSessionID, startOptions
        case advertisedOptions, availableCommands, createdAt, lastActivityAt
        case endedReason, archivedReason
        case usage, lastTurnUsage, costToDate, plans, additionalDirectories, mcpServers
    }

    struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
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
                archivedReason: Agent.ArchivedReason? = nil,
                usage: Usage? = nil,
                lastTurnUsage: TurnUsage? = nil,
                costToDate: [String: Decimal] = [:],
                plans: [Plan] = [],
                additionalDirectories: [URL] = [],
                mcpServers: [MCPServer] = [],
                unknownFields: [String: JSONValue] = [:]) {
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
        self.usage = usage
        self.lastTurnUsage = lastTurnUsage
        self.costToDate = costToDate
        self.plans = plans
        self.additionalDirectories = additionalDirectories
        self.mcpServers = mcpServers
        self.unknownFields = unknownFields
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
