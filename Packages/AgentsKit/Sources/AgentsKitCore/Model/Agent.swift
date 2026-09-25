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
    /// What it is doing. Defaults to `starting` in the memberwise `init`, with no
    /// ending and no reason for one (FR-002).
    ///
    /// It used to default to `stopped` with `endedReason: .endTurn`, which was never
    /// carelessness: `isConsistent` requires a stopped agent to carry a reason, and
    /// `endTurn` is the only one whose `summary` is `nil`, so it was the cheapest
    /// reason that would not print something false on the row. The falsehood moved
    /// into the record instead, where it was broadcast to every window before the
    /// first turn began.
    public var state: AgentState
    /// The state string a newer build wrote, when this build has never heard of it.
    ///
    /// The one thing this feature keeps in memory and not on the wire. It is not in
    /// `CodingKeys` on purpose — the `known` set that `unknownFields` is filtered
    /// against is built from `CodingKeys.allCases`, and adding this to it would make
    /// the filter start dropping a key that really is on the record.
    ///
    /// Held so `encode` can put the original back rather than quietly replacing what
    /// that build knew with `stopped` (FR-021). Cleared the moment a transition writes
    /// a state of our own, in `DaemonCore.move`.
    public var rawState: String?
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

    /// This agent's own ceiling, when the reader has given it one. Nil means the
    /// app-wide per-agent limit applies.
    ///
    /// This is how "let this one go on" is expressed: the allowance raises *this*
    /// agent's ceiling and touches nothing else. Set only by the reader, only through
    /// `agents/setCeiling`.
    public var costCeiling: Cost?

    /// What the agent said it was going to do. The current one is last.
    public var plans: [Plan]

    /// Folders beyond `cwd` that this agent may reach, where the runtime takes them.
    public var additionalDirectories: [URL]

    /// MCP servers attached to this agent, sent when its session is made.
    public var mcpServers: [MCPServer]

    /// What was typed while it was working, in the order it was typed. Sent one at a
    /// time as each turn ends.
    public var queuedPrompts: [QueuedPrompt]

    /// What the agent offered as a next thing to ask, from the turn that just ended.
    /// Cleared the moment the next prompt goes: a suggestion is about the turn it came
    /// from, and a stale one is worse than none.
    public var suggestedPrompts: [SuggestedPrompt]

    /// What the agent said about how the work went, from the turn that just ended.
    /// Cleared by the person's next prompt, for the same reason the suggestions are:
    /// it is an account of one turn, and a stale one is worse than none.
    public var report: WorkReport?

    /// Whether this agent has already been asked to account for an ending it did not
    /// account for. Set when the question is enqueued, cleared by a prompt from the
    /// person. One ask per silence, and the agent cannot write it.
    public var outcomeAsked: Bool

    /// Whether the title is the agent's own, given with the call that ends its turn.
    ///
    /// Once it is, a title from the runtime no longer replaces it. That is not a
    /// nicety: Claude's adapter generates a title of its own *when the turn ends*,
    /// which is after the agent's last tool call, so without this the agent's name for
    /// the work would be overwritten a moment after it was given.
    public var titledByAgent: Bool

    public var createdAt: Date
    public var lastActivityAt: Date
    /// A finished conversation nobody has looked at since it finished. Set by the
    /// daemon when an agent finishes with nobody watching, cleared when a presence
    /// report puts the conversation in front of an active person. Only ever true of a
    /// finished agent: a running chat is not something you have "read", and a stopped
    /// one is under its own heading.
    public var isUnread: Bool
    /// Which report the person has had in front of them, by its `at`. A report that
    /// wants a person is news once: seen, it stops being a notification to send, though
    /// the agent stays under Needs attention until it is answered. A newer report has
    /// another `at`, so it is news again. The report's own time rather than the clock's,
    /// so no two clocks are ever compared.
    public var reportSeenAt: Date?
    public var endedReason: EndedReason?
    public var archivedReason: ArchivedReason?

    /// The workflow that started or resumed this agent, if one did. What lets the agent
    /// list say where an agent nobody typed for came from.
    public var startedByWorkflow: String?
    /// The workflow run that caused this agent, if one did. Read to work out how deep a
    /// chain is when this agent's own events fire something further.
    public var startedByRun: UUID?

    /// How many times in a row this chat has been picked back up after the daemon
    /// went, without a turn since reaching its own end. On the record and not in
    /// memory because the event it counts is the daemon dying.
    public var restartPickUps: Int

    /// Keys a newer version wrote that this one does not know. Kept so that opening a
    /// record in an older build and saving it does not quietly delete them.
    public var unknownFields: [String: JSONValue]

    /// Everywhere this agent may read and write: its folder, and any it was given.
    public var folderScope: FolderScope { FolderScope(folders: [cwd] + additionalDirectories) }

    /// Only `byUser` exists in this feature: nothing archives itself.
    public enum ArchivedReason: String, Codable, Hashable, Sendable {
        case byUser

        /// Archived for a reason this build does not know is still archived.
        public init(from decoder: any Decoder) throws {
            let written = try decoder.singleValueContainer().decode(String.self)
            self = ArchivedReason(rawValue: written) ?? .byUser
        }
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        runtimeID = try c.decode(String.self, forKey: .runtimeID)
        cwd = try c.decode(URL.self, forKey: .cwd)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        // Lenient, because the alternative is losing the agent. `state` is a
        // `String` raw-value enum, so an unknown value thrown from here fails the
        // whole `Agent`, and `loadAll` files it under `unreadable` — the agent simply
        // vanishes from the app with nothing a person can see. Every *other* field a
        // newer build might add is already protected by `unknownFields`; `state` was
        // not, because it is a known key.
        //
        // `unrecognised` is the honest reading and already means exactly this
        // elsewhere: not in the protocol's list and not one of ours, belonging in the
        // record rather than rounded to the nearest reason we do recognise.
        // `WorkOutcome.init(wire:)` takes the same position for the same reason. It is
        // never read as a completion.
        //
        // The honest limit: this protects builds that *have* it from states added
        // *after* it. A build predating it meeting a `starting` record still drops
        // that agent. That is written down in `contracts/record-and-wire.md`, and it
        // is the argument for doing this now rather than the next time a state is
        // added.
        let writtenState = try c.decode(String.self, forKey: .state)
        if let known = AgentState(rawValue: writtenState) {
            state = known
            rawState = nil
        } else {
            state = .stopped
            rawState = writtenState
        }
        runtimeSessionID = try c.decodeIfPresent(String.self, forKey: .runtimeSessionID)
        startOptions = try c.decodeIfPresent(StartOptions.self, forKey: .startOptions) ?? .none
        // Records written before the controls moved onto the prompt bar have none.
        advertisedOptions = try c.decodeIfPresent([ConfigOption].self, forKey: .advertisedOptions) ?? []
        availableCommands = try c.decodeIfPresent([SlashCommand].self, forKey: .availableCommands) ?? []
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        lastActivityAt = try c.decode(Date.self, forKey: .lastActivityAt)
        isUnread = try c.decodeIfPresent(Bool.self, forKey: .isUnread) ?? false
        reportSeenAt = try c.decodeIfPresent(Date.self, forKey: .reportSeenAt)
        endedReason = try c.decodeIfPresent(EndedReason.self, forKey: .endedReason)
        // A state we have never heard of, and no reason beside it, is an ending
        // nothing vouched for. Only when there is no reason: a newer build that wrote
        // `maxTokens` beside a state of its own said something this build understands,
        // and replacing it would hand that build back a reason we invented — on the
        // one key the lenient decode exists to preserve, while `unknownFields` guards
        // every other. Either way this decodes to `stopped` and is never read as a
        // completion.
        if rawState != nil && endedReason == nil { endedReason = .unrecognised }
        archivedReason = try c.decodeIfPresent(ArchivedReason.self, forKey: .archivedReason)
        // Every field below arrived with 003. A record written before it has none of
        // them, and must still open.
        usage = try c.decodeIfPresent(Usage.self, forKey: .usage)
        lastTurnUsage = try c.decodeIfPresent(TurnUsage.self, forKey: .lastTurnUsage)
        costToDate = try c.decodeIfPresent([String: Decimal].self, forKey: .costToDate) ?? [:]
        // New in 010. A record written before limits existed has no ceiling of its
        // own, which is the app-wide per-agent limit applying.
        costCeiling = try c.decodeIfPresent(Cost.self, forKey: .costCeiling)
        plans = try c.decodeIfPresent([Plan].self, forKey: .plans) ?? []
        additionalDirectories = try c.decodeIfPresent([URL].self, forKey: .additionalDirectories) ?? []
        mcpServers = try c.decodeIfPresent([MCPServer].self, forKey: .mcpServers) ?? []
        // New in 004. A record written before it has nothing waiting.
        queuedPrompts = try c.decodeIfPresent([QueuedPrompt].self, forKey: .queuedPrompts) ?? []
        // Newer than the field above, and on the record rather than held in memory so
        // the chips are still there when the app is opened again on a turn that ended
        // last night.
        suggestedPrompts = try c.decodeIfPresent([SuggestedPrompt].self, forKey: .suggestedPrompts) ?? []
        // New in 008, and optional, so every record written before workflows existed
        // opens unchanged and needs nothing migrating.
        startedByWorkflow = try c.decodeIfPresent(String.self, forKey: .startedByWorkflow)
        startedByRun = try c.decodeIfPresent(UUID.self, forKey: .startedByRun)
        // New in 011, and counted from nothing, so every record written before the
        // restart guard existed opens as a chat that has never been picked back up.
        restartPickUps = try c.decodeIfPresent(Int.self, forKey: .restartPickUps) ?? 0
        // New in 014. A record written before agents could say how it went opens as an
        // agent that never reported and has never been asked — which is the truth about
        // it, and is why neither of these is a completion.
        report = try c.decodeIfPresent(WorkReport.self, forKey: .report)
        outcomeAsked = try c.decodeIfPresent(Bool.self, forKey: .outcomeAsked) ?? false
        // New with the title on `finish_turn`. An older record's title came from the
        // runtime or the prompt, so a runtime title may still replace it.
        titledByAgent = try c.decodeIfPresent(Bool.self, forKey: .titledByAgent) ?? false
        // Only the keys this build does not know are read as open-ended values.
        // Reading the whole record that way too — which is what this did — decoded
        // every option, command and plan a second time, for every agent, on every
        // change a window hears about.
        let known = Set(CodingKeys.allCases.map(\.stringValue))
        unknownFields = [:]
        if let extra = try? decoder.container(keyedBy: AnyKey.self) {
            for key in extra.allKeys where !known.contains(key.stringValue) {
                unknownFields[key.stringValue] = (try? extra.decode(JSONValue.self, forKey: key)) ?? .null
            }
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(runtimeID, forKey: .runtimeID)
        try c.encode(cwd, forKey: .cwd)
        try c.encodeIfPresent(title, forKey: .title)
        // The original string where there was one, so a state from a newer build
        // survives a round trip through this one instead of being silently downgraded
        // to `stopped` (FR-021).
        try c.encode(rawState ?? state.rawValue, forKey: .state)
        try c.encodeIfPresent(runtimeSessionID, forKey: .runtimeSessionID)
        try c.encode(startOptions, forKey: .startOptions)
        try c.encode(advertisedOptions, forKey: .advertisedOptions)
        try c.encode(availableCommands, forKey: .availableCommands)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(lastActivityAt, forKey: .lastActivityAt)
        if isUnread { try c.encode(isUnread, forKey: .isUnread) }
        try c.encodeIfPresent(reportSeenAt, forKey: .reportSeenAt)
        try c.encodeIfPresent(endedReason, forKey: .endedReason)
        try c.encodeIfPresent(archivedReason, forKey: .archivedReason)
        try c.encodeIfPresent(usage, forKey: .usage)
        try c.encodeIfPresent(lastTurnUsage, forKey: .lastTurnUsage)
        if !costToDate.isEmpty { try c.encode(costToDate, forKey: .costToDate) }
        try c.encodeIfPresent(costCeiling, forKey: .costCeiling)
        if !plans.isEmpty { try c.encode(plans, forKey: .plans) }
        if !additionalDirectories.isEmpty {
            try c.encode(additionalDirectories, forKey: .additionalDirectories)
        }
        if !mcpServers.isEmpty { try c.encode(mcpServers, forKey: .mcpServers) }
        if !queuedPrompts.isEmpty { try c.encode(queuedPrompts, forKey: .queuedPrompts) }
        if !suggestedPrompts.isEmpty { try c.encode(suggestedPrompts, forKey: .suggestedPrompts) }
        try c.encodeIfPresent(startedByWorkflow, forKey: .startedByWorkflow)
        try c.encodeIfPresent(startedByRun, forKey: .startedByRun)
        if restartPickUps != 0 { try c.encode(restartPickUps, forKey: .restartPickUps) }
        try c.encodeIfPresent(report, forKey: .report)
        if outcomeAsked { try c.encode(outcomeAsked, forKey: .outcomeAsked) }
        if titledByAgent { try c.encode(titledByAgent, forKey: .titledByAgent) }
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
        case advertisedOptions, availableCommands, createdAt, lastActivityAt, isUnread, reportSeenAt
        case endedReason, archivedReason
        case usage, lastTurnUsage, costToDate, costCeiling, plans, additionalDirectories, mcpServers
        case queuedPrompts, suggestedPrompts
        case startedByWorkflow, startedByRun
        case restartPickUps
        case report, outcomeAsked
        case titledByAgent
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
                state: AgentState = .starting,
                runtimeSessionID: String? = nil,
                startOptions: StartOptions = .none,
                advertisedOptions: [ConfigOption] = [],
                availableCommands: [SlashCommand] = [],
                createdAt: Date = Date(),
                lastActivityAt: Date = Date(),
                isUnread: Bool = false,
                reportSeenAt: Date? = nil,
                endedReason: EndedReason? = nil,
                archivedReason: Agent.ArchivedReason? = nil,
                usage: Usage? = nil,
                lastTurnUsage: TurnUsage? = nil,
                costToDate: [String: Decimal] = [:],
                costCeiling: Cost? = nil,
                plans: [Plan] = [],
                additionalDirectories: [URL] = [],
                mcpServers: [MCPServer] = [],
                queuedPrompts: [QueuedPrompt] = [],
                suggestedPrompts: [SuggestedPrompt] = [],
                startedByWorkflow: String? = nil,
                startedByRun: UUID? = nil,
                restartPickUps: Int = 0,
                report: WorkReport? = nil,
                outcomeAsked: Bool = false,
                titledByAgent: Bool = false,
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
        self.isUnread = isUnread
        self.reportSeenAt = reportSeenAt
        self.endedReason = endedReason
        self.archivedReason = archivedReason
        self.usage = usage
        self.lastTurnUsage = lastTurnUsage
        self.costToDate = costToDate
        self.costCeiling = costCeiling
        self.plans = plans
        self.additionalDirectories = additionalDirectories
        self.mcpServers = mcpServers
        self.queuedPrompts = queuedPrompts
        self.suggestedPrompts = suggestedPrompts
        self.startedByWorkflow = startedByWorkflow
        self.startedByRun = startedByRun
        self.restartPickUps = restartPickUps
        self.report = report
        self.outcomeAsked = outcomeAsked
        self.titledByAgent = titledByAgent
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

    /// An agent's own title, made fit for a row: one line, spaces collapsed, and no
    /// longer than a prompt-made title may be. Nil when nothing is left, which the
    /// daemon refuses rather than drawing a blank row.
    public static func cleanedTitle(_ raw: String) -> String? {
        let oneLine = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !oneLine.isEmpty else { return nil }
        return oneLine.count > 80 ? String(oneLine.prefix(79)) + "…" : oneLine
    }

    /// Whether a restarting daemon may bring this chat back by itself: it was working
    /// when the daemon went, whatever it was doing and however many times before.
    ///
    /// There used to be a threshold of one, on the theory that a chat cut off again on
    /// the very turn it was brought back with was the likeliest reason the daemon went.
    /// Alex removed it (2026-09-21): a chat left stopped after a restart is work
    /// abandoned by nobody, and a daemon restarted a few times in a row — every build
    /// of the app is one — was leaving a trail of them. `restartPickUps` is still
    /// counted, for the transcript to say.
    public var mayBePickedUpAfterRestart: Bool {
        state == .stopped && endedReason == .daemonGone
    }

    // MARK: What the reader will allow
    //
    // Four rules, all computed and all taking the limits as a parameter. None of them
    // is stored, and none of them must ever become stored state: a flag written when
    // a limit was reached would still say so after the reader raised the limit, and
    // would not say so for an agent that was already over one they have just lowered.
    // Computing means lowering a limit is instantly true of every agent that exists,
    // with no write and no sweep.

    /// The ceiling this agent is actually held to: its own if it has one, otherwise
    /// the app-wide per-agent limit. The only place that precedence is decided.
    public func ceiling(under limits: CostLimits) -> Cost? {
        costCeiling ?? limits.perAgent
    }

    /// Whether this agent has spent everything it is allowed to.
    ///
    /// *Reaches*, not exceeds: the spec's word, so an agent exactly at its limit is
    /// at it. False when there is no ceiling, and false when the agent is unmeasured —
    /// a runtime that reports no cost can never be capped, and must never be treated
    /// as though it had been.
    public func isAtCostLimit(under limits: CostLimits) -> Bool {
        guard !costIsUnmeasured, let ceiling = ceiling(under: limits) else { return false }
        return (costToDate[ceiling.currency] ?? 0) >= ceiling.amount
    }

    /// What is left before it stops. `nil` when uncapped, which is how a view knows to
    /// show nothing rather than a headroom that does not exist.
    public func costHeadroom(under limits: CostLimits) -> Decimal? {
        guard !costIsUnmeasured else { return nil }
        return CostLimits.headroom(of: ceiling(under: limits), against: costToDate)
    }

    /// A turn has ended and the runtime said nothing at all about money.
    ///
    /// Two shapes of silence, and both are this: a runtime that sends a usage block
    /// with no price in it, and one that sends no usage block at all. Grok does the
    /// second, so keying this on `lastTurnUsage` being present would miss the very
    /// runtime the rule exists for.
    ///
    /// `usage?.cost` is in here because silence means *nowhere*. A runtime that quotes
    /// its price on the mid-turn usage update and not on the turn's reply — which is
    /// every Claude agent — has said what it costs, and saying "Not measured" over the
    /// top of a figure the app is holding was this predicate's own bug, not the
    /// runtime's. It also covers every record written before the cost was banked.
    ///
    /// Settled rather than running, so nothing is claimed mid-turn — a label that
    /// comes and goes is one you stop trusting, and a turn that has not ended yet
    /// has not failed to report anything.
    ///
    /// Never capped, never counted, and always labelled as such. The worst failure
    /// available to this feature is a reader believing an agent is covered by a limit
    /// that cannot touch it, so this is shown wherever a cost would otherwise be.
    public var costIsUnmeasured: Bool {
        !state.hasTurnInFlight && costToDate.isEmpty && lastTurnUsage?.cost == nil
            && usage?.cost == nil && lastActivityAt > createdAt
    }

    /// The invariants from the data model.
    ///
    /// Asserted only in tests until 020; from Phase 5 of that feature these are checked
    /// wherever an agent is written and wherever one is read, so a record that cannot
    /// be true never reaches disk and one already there is mended rather than believed.
    public var isConsistent: Bool {
        if state == .archived && archivedReason == nil { return false }
        if state == .stopped && endedReason == nil { return false }
        if state == .finished && endedReason != .endTurn { return false }
        // A new agent has not ended and has not been put away. This is the invariant
        // that makes `starting` worth having: the reason the old code wrote `stopped`
        // with `endTurn` was that rule 2 demanded *some* reason, and now nothing does.
        if state == .starting && (endedReason != nil || archivedReason != nil) { return false }
        return true
    }
}
