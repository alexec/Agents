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
    /// The names attached to this conversation, with person or agent ownership.
    /// Empty for records written before session labels existed.
    public var labels: [SessionLabel]
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
    /// Which machine this agent runs on, as the window that heard of it says (037).
    /// Kept in memory only and out of `CodingKeys` for the same reason as `rawState`:
    /// the daemon that owns the record does not know it has a name elsewhere, and the
    /// window stamps it on arrival. A record read without it is this Mac's.
    public var host: HostID = .mac
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

    /// What it left running in the background — shells, subagents — and the last few
    /// that finished (057). Only a runtime told it may send these ever fills it.
    public var background: [BackgroundItem]

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

    /// Whether the person has put this chat down to come back to (040). Absent is not
    /// parked. It sits beside `state`, `endedReason` and `report` and replaces none of
    /// them, so unparking is only removing it and the chat is back where its ending
    /// says. Written by the daemon alone: a person parks and unparks, a person's prompt
    /// unparks, and archiving clears it.
    public var parking: Parking?

    /// Where the agent asked, on the call that ended its turn, to be put once that
    /// turn is really over: parked, or archived. Absent is where its ending puts it.
    /// Written only by `finish_turn`, and cleared when the turn ends, is stopped, or
    /// the person sends something — a turn ending any other way than its own, or work
    /// moved on by the person, is not what the ask was about.
    public var afterTurn: AfterTurn?

    /// Whether the title is the agent's own, given with the call that ends its turn.
    ///
    /// Once it is, a title from the runtime no longer replaces it. That is not a
    /// nicety: Claude's adapter generates a title of its own *when the turn ends*,
    /// which is after the agent's last tool call, so without this the agent's name for
    /// the work would be overwritten a moment after it was given.
    public var titledByAgent: Bool

    /// The pool entry the chat is on now (052): which runtime *and* which way of paying
    /// for it, since Codex on its plan and Codex on a key are two entries. Nil when it
    /// started outside the pool.
    public var poolEntryID: UUID?

    /// The chat's own "carry on when this runs out" is off (052, FR-003). Off is rare, so
    /// only written when true.
    public var switchingOff: Bool
    /// Waiting for an allowance to come back, when every runtime in the pool was out
    /// (052, US4). Kept on the record, so a restart still resumes it.
    public var allowanceWait: AllowanceWait?

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
    /// The agent whose `start_agent` call made this one, if one did (028). Set once,
    /// never changed. It is what lets that agent stop and archive this one, what keeps
    /// the tools from this one, and what counts it against its project's three.
    public var startedByAgent: UUID?
    /// How deep a workflow fire caused by this agent is, when the agent that started it
    /// was part of a workflow chain (028). Taken when this agent is made, because the
    /// starter's run can end long before this agent does, and a depth read from it then
    /// would be zero — the loop the chain limit exists to stop, begun again.
    public var chainDepth: Int?
    /// What it is waiting to happen, if anything (042). Made by a tool call mid-turn
    /// and kept here, not on the report, so whatever the turn then reports leaves it be.
    public var eventWait: EventWait?
    /// The worktree this agent works in, if it does: the one it was started in (030) or
    /// moved into (053). Its project is the worktree's project, not its `cwd`.
    public var worktree: AgentWorktree?
    /// A move asked for and not yet made (053). Applied when the turn ends, or at once
    /// when none is running. Cleared when applied, cancelled, archived or deleted.
    public var pendingMove: PendingMove?
    /// Where git's view of this agent's changes is measured from: the commit its folder
    /// was on when it started (035). Nil outside a repository, or where git could not
    /// answer at the start.
    public var startingPoint: StartingPoint?
    /// The `requestID` of the start that made this agent, when the caller sent one
    /// (029). Written on the first save, never changed. It is how a start retried after
    /// its reply was lost finds the agent the first attempt made, including across a
    /// daemon restart, and how a phone that dropped mid-send finds it in the list.
    public var startRequestID: UUID?

    /// How many times in a row this chat has been picked back up after the daemon
    /// went, without a turn since reaching its own end. On the record and not in
    /// memory because the event it counts is the daemon dying.
    public var restartPickUps: Int

    /// When it was last archived (051): the start of the time it is kept before it is
    /// retired. Cleared on unarchiving.
    public var archivedAt: Date?
    /// What its row says about being retired, set by the daemon's check (051). Only
    /// ever on an archived agent.
    public var retirement: Retirement?

    /// This agent's own command sandbox choice (064, FR-003b). Nil follows its runtime's
    /// default; set only by the person, or by **Continue without sandbox**.
    public var sandboxOverride: SandboxChoice?
    /// The sandbox its latest turn started with (FR-010), written at every spawn.
    public var effectiveSandbox: EffectiveSandbox?
    /// The sandbox card waiting for the person's answer, if one is (064, FR-007a).
    public var pendingSandboxFailure: SandboxFailureRecord?
    /// Its `cwd` was not there when the daemon last looked (#119): a worktree removed
    /// after a merge, a folder moved, a disk ejected. Written by the daemon, which looks
    /// again on its heartbeat and before every send, so rows and the header say so
    /// before anybody types. Nil while the folder is there.
    public var missingFolder: MissingFolder?
    /// The id of the root this record was made in (#228): `root-id.json` beside
    /// `agents/`. A record whose stamp is not this root's was copied in from somewhere
    /// else, and its runtime session, worktree and folder are somebody else's live work.
    /// The daemon shows it, stopped, and never starts a runtime for it.
    public var madeInRoot: String?
    /// How a queued helper is to be started once a place frees (#362): what its starter
    /// asked for, kept so the daemon makes that agent later, after a restart too. Set
    /// only while `state` is `queued`. Its prompt is the first of `queuedPrompts`.
    public var queuedStart: QueuedStart?
    /// The three lists that are nearly all of a record — the options and commands the
    /// runtime advertised, and the plans — are empty here and still on disk (051). An
    /// archived agent nobody is reading is held this way: 1.4 KB rather than 24.
    ///
    /// In memory only and out of `CodingKeys`, like `rawState`, because it is a fact
    /// about this copy and not about the agent. `AgentStore.save` reads the lists back
    /// before writing, so a slim copy can never reach `agent.json`.
    public var isSlim = false
    /// The three lists were left out of this copy on the wire (#107, #203): a lean list, or
    /// an `agent/changed` saying something other than the lists moved. Their being empty
    /// here says nothing about the agent's, and `keepingLists(of:)` keeps the ones held.
    /// Never on a record the daemon keeps, and written only when true.
    public var listsLeftOut: Bool = false

    /// Keys a newer version wrote that this one does not know. Kept so that opening a
    /// record in an older build and saving it does not quietly delete them.
    public var unknownFields: [String: JSONValue]

    /// Everywhere this agent may read and write: its folder, and any it was given.
    /// The project this agent belongs to, as projects compare folders. Its `cwd` is
    /// where it works; in a worktree those are two different folders (030).
    public var projectFolder: URL { Project.standardize(worktree?.project ?? cwd) }

    public var folderScope: FolderScope { FolderScope(folders: [cwd] + additionalDirectories) }

    /// Why an archived agent was archived: by the person, or by an agent.
    public enum ArchivedReason: String, Codable, Hashable, Sendable {
        case byUser
        /// Put away by an agent — the one that started it (028), or itself, as it
        /// asked on the call that ended its turn.
        case byAgent

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
        labels = try c.decodeIfPresent([SessionLabel].self, forKey: .labels) ?? []
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
        // Always written, and still read as empty when absent: a build that stops
        // writing either must not cost an older reader the whole agent.
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
        // Written only when there is one, or when it is not empty.
        usage = try c.decodeIfPresent(Usage.self, forKey: .usage)
        lastTurnUsage = try c.decodeIfPresent(TurnUsage.self, forKey: .lastTurnUsage)
        costToDate = try c.decodeIfPresent([String: Decimal].self, forKey: .costToDate) ?? [:]
        // New in 010. A record written before limits existed has no ceiling of its
        // own, which is the app-wide per-agent limit applying.
        costCeiling = try c.decodeIfPresent(Cost.self, forKey: .costCeiling)
        plans = try c.decodeIfPresent([Plan].self, forKey: .plans) ?? []
        background = try c.decodeIfPresent([BackgroundItem].self, forKey: .background) ?? []
        additionalDirectories = try c.decodeIfPresent([URL].self, forKey: .additionalDirectories) ?? []
        mcpServers = try c.decodeIfPresent([MCPServer].self, forKey: .mcpServers) ?? []
        // Written only when something is waiting.
        queuedPrompts = try c.decodeIfPresent([QueuedPrompt].self, forKey: .queuedPrompts) ?? []
        // On the record rather than held in memory so the chip is still there when the
        // app is opened again on a turn that ended last night.
        suggestedPrompts = try c.decodeIfPresent([SuggestedPrompt].self, forKey: .suggestedPrompts) ?? []
        // New in 008, and optional, so every record written before workflows existed
        // opens unchanged and needs nothing migrating.
        startedByWorkflow = try c.decodeIfPresent(String.self, forKey: .startedByWorkflow)
        startedByRun = try c.decodeIfPresent(UUID.self, forKey: .startedByRun)
        startedByAgent = try c.decodeIfPresent(UUID.self, forKey: .startedByAgent)
        chainDepth = try c.decodeIfPresent(Int.self, forKey: .chainDepth)
        eventWait = try c.decodeIfPresent(EventWait.self, forKey: .eventWait)
        // Optional: an agent outside a worktree works in its project folder.
        worktree = try c.decodeIfPresent(AgentWorktree.self, forKey: .worktree)
        pendingMove = (try? c.decodeIfPresent(PendingMove.self, forKey: .pendingMove)) ?? nil
        startingPoint = try c.decodeIfPresent(StartingPoint.self, forKey: .startingPoint)
        startRequestID = try c.decodeIfPresent(UUID.self, forKey: .startRequestID)
        // New in 011, and counted from nothing, so every record written before the
        // restart guard existed opens as a chat that has never been picked back up.
        restartPickUps = try c.decodeIfPresent(Int.self, forKey: .restartPickUps) ?? 0
        // New in 014. A record written before agents could say how it went opens as an
        // agent that never reported and has never been asked — which is the truth about
        // it, and is why neither of these is a completion.
        //
        // An outcome this build does not know is a report that never arrived, not an
        // agent that cannot be read (039): a newer daemon's sixth word must not make
        // the whole record vanish from an older phone's list.
        do {
            report = try c.decodeIfPresent(WorkReport.self, forKey: .report)
        } catch is WorkReport.UnknownOutcome {
            report = nil
        }
        outcomeAsked = try c.decodeIfPresent(Bool.self, forKey: .outcomeAsked) ?? false
        // New with the title on `finish_turn`. An older record's title came from the
        // runtime or the prompt, so a runtime title may still replace it.
        titledByAgent = try c.decodeIfPresent(Bool.self, forKey: .titledByAgent) ?? false
        // 052's, read and never written since 065. Kept: 052 is after the cut-off
        // (#58: 051), so a record a 052 build wrote must still open.
        poolEntryID = try c.decodeIfPresent(UUID.self, forKey: .poolEntryID)
        switchingOff = try c.decodeIfPresent(Bool.self, forKey: .switchingOff) ?? false
        allowanceWait = try c.decodeIfPresent(AllowanceWait.self, forKey: .allowanceWait)
        // Written only when parked.
        parking = try c.decodeIfPresent(Parking.self, forKey: .parking)
        // Absent when nothing was asked. A word this build does not know — a newer
        // build's, or the `archive` agents could once ask for — asked for nothing.
        afterTurn = (try? c.decodeIfPresent(AfterTurn.self, forKey: .afterTurn)) ?? nil
        // Stamped whenever an agent is archived (051), and absent on one that is not.
        archivedAt = try c.decodeIfPresent(Date.self, forKey: .archivedAt)
        retirement = (try? c.decodeIfPresent(Retirement.self, forKey: .retirement)) ?? nil
        // New in 064. Absent on everything written before it: the runtime's default.
        sandboxOverride = try c.decodeIfPresent(SandboxChoice.self, forKey: .sandboxOverride)
        effectiveSandbox = (try? c.decodeIfPresent(EffectiveSandbox.self, forKey: .effectiveSandbox)) ?? nil
        pendingSandboxFailure = (try? c.decodeIfPresent(SandboxFailureRecord.self, forKey: .pendingSandboxFailure)) ?? nil
        missingFolder = (try? c.decodeIfPresent(MissingFolder.self, forKey: .missingFolder)) ?? nil
        listsLeftOut = try c.decodeIfPresent(Bool.self, forKey: .listsLeftOut) ?? false
        madeInRoot = (try? c.decodeIfPresent(String.self, forKey: .madeInRoot)) ?? nil
        queuedStart = (try? c.decodeIfPresent(QueuedStart.self, forKey: .queuedStart)) ?? nil
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
        if !labels.isEmpty { try c.encode(labels, forKey: .labels) }
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
        if !background.isEmpty { try c.encode(background, forKey: .background) }
        if !additionalDirectories.isEmpty {
            try c.encode(additionalDirectories, forKey: .additionalDirectories)
        }
        if !mcpServers.isEmpty { try c.encode(mcpServers, forKey: .mcpServers) }
        if !queuedPrompts.isEmpty { try c.encode(queuedPrompts, forKey: .queuedPrompts) }
        if !suggestedPrompts.isEmpty { try c.encode(suggestedPrompts, forKey: .suggestedPrompts) }
        try c.encodeIfPresent(startedByWorkflow, forKey: .startedByWorkflow)
        try c.encodeIfPresent(startedByRun, forKey: .startedByRun)
        try c.encodeIfPresent(startedByAgent, forKey: .startedByAgent)
        try c.encodeIfPresent(chainDepth, forKey: .chainDepth)
        try c.encodeIfPresent(eventWait, forKey: .eventWait)
        try c.encodeIfPresent(worktree, forKey: .worktree)
        try c.encodeIfPresent(pendingMove, forKey: .pendingMove)
        try c.encodeIfPresent(startingPoint, forKey: .startingPoint)
        try c.encodeIfPresent(startRequestID, forKey: .startRequestID)
        if restartPickUps != 0 { try c.encode(restartPickUps, forKey: .restartPickUps) }
        try c.encodeIfPresent(report, forKey: .report)
        if outcomeAsked { try c.encode(outcomeAsked, forKey: .outcomeAsked) }
        if titledByAgent { try c.encode(titledByAgent, forKey: .titledByAgent) }
        // 052's poolEntryID, switchingOff and allowanceWait are read from an older record
        // and never written again (065): nothing sets them, and a wait found at launch is
        // cleared. They go once the #58 cut-off moves past 052.
        try c.encodeIfPresent(parking, forKey: .parking)
        try c.encodeIfPresent(afterTurn, forKey: .afterTurn)
        try c.encodeIfPresent(archivedAt, forKey: .archivedAt)
        try c.encodeIfPresent(retirement, forKey: .retirement)
        try c.encodeIfPresent(sandboxOverride, forKey: .sandboxOverride)
        try c.encodeIfPresent(effectiveSandbox, forKey: .effectiveSandbox)
        try c.encodeIfPresent(pendingSandboxFailure, forKey: .pendingSandboxFailure)
        try c.encodeIfPresent(missingFolder, forKey: .missingFolder)
        if listsLeftOut { try c.encode(listsLeftOut, forKey: .listsLeftOut) }
        try c.encodeIfPresent(madeInRoot, forKey: .madeInRoot)
        try c.encodeIfPresent(queuedStart, forKey: .queuedStart)
        // Whatever a newer version wrote, written back out beside our own fields.
        if !unknownFields.isEmpty {
            var extra = encoder.container(keyedBy: AnyKey.self)
            for (key, value) in unknownFields {
                try extra.encode(value, forKey: AnyKey(stringValue: key))
            }
        }
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case id, runtimeID, cwd, title, labels, state, runtimeSessionID, startOptions
        case advertisedOptions, availableCommands, createdAt, lastActivityAt, isUnread, reportSeenAt
        case endedReason, archivedReason
        case usage, lastTurnUsage, costToDate, costCeiling, plans, additionalDirectories, mcpServers
        case queuedPrompts, suggestedPrompts
        case startedByWorkflow, startedByRun, startedByAgent, chainDepth, eventWait, startRequestID
        case worktree
        case pendingMove
        case startingPoint
        case restartPickUps
        case report, outcomeAsked
        case titledByAgent
        case poolEntryID, switchingOff, allowanceWait
        case parking
        case afterTurn
        case background
        case archivedAt, retirement
        case sandboxOverride, effectiveSandbox, pendingSandboxFailure
        case missingFolder
        case listsLeftOut
        case madeInRoot
        case queuedStart
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
                labels: [SessionLabel] = [],
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
                background: [BackgroundItem] = [],
                additionalDirectories: [URL] = [],
                mcpServers: [MCPServer] = [],
                queuedPrompts: [QueuedPrompt] = [],
                suggestedPrompts: [SuggestedPrompt] = [],
                startedByWorkflow: String? = nil,
                startedByRun: UUID? = nil,
                startedByAgent: UUID? = nil,
                chainDepth: Int? = nil,
                eventWait: EventWait? = nil,
                worktree: AgentWorktree? = nil,
                pendingMove: PendingMove? = nil,
                startingPoint: StartingPoint? = nil,
                startRequestID: UUID? = nil,
                restartPickUps: Int = 0,
                report: WorkReport? = nil,
                outcomeAsked: Bool = false,
                titledByAgent: Bool = false,
                parking: Parking? = nil,
                afterTurn: AfterTurn? = nil,
                archivedAt: Date? = nil,
                retirement: Retirement? = nil,
                unknownFields: [String: JSONValue] = [:]) {
        self.id = id
        self.runtimeID = runtimeID
        self.cwd = cwd
        self.title = title
        self.labels = labels
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
        self.background = background
        self.additionalDirectories = additionalDirectories
        self.mcpServers = mcpServers
        self.queuedPrompts = queuedPrompts
        self.suggestedPrompts = suggestedPrompts
        self.startedByWorkflow = startedByWorkflow
        self.startedByRun = startedByRun
        self.startedByAgent = startedByAgent
        self.chainDepth = chainDepth
        self.eventWait = eventWait
        self.worktree = worktree
        self.pendingMove = pendingMove
        self.startingPoint = startingPoint
        self.startRequestID = startRequestID
        self.restartPickUps = restartPickUps
        self.report = report
        self.outcomeAsked = outcomeAsked
        self.titledByAgent = titledByAgent
        self.poolEntryID = nil
        self.switchingOff = false
        self.allowanceWait = nil
        self.parking = parking
        self.afterTurn = afterTurn
        self.archivedAt = archivedAt
        self.retirement = retirement
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
    /// counted, and a chat is left stopped only once several pick-ups in a row have gone
    /// down with the daemon (#209): a crash loop, not a few builds. Every gate reads it
    /// here — recovery, the ending's events, a workflow's run — so one left stopped ends
    /// as any stopped chat does and lets its run go.
    public var mayBePickedUpAfterRestart: Bool {
        state == .stopped && endedReason == .daemonGone && restartPickUps < Self.pickUpsBeforeLeavingAlone
    }

    /// How many pick-ups in a row may go down with the daemon, no turn of the chat
    /// finishing between them, before a restart leaves the chat stopped (#209).
    public static let pickUpsBeforeLeavingAlone = 3

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

    /// The ceiling that lets this agent carry on once more, from any device (033).
    ///
    /// One more step of the ceiling it is held to, on top of what it has spent — a
    /// concrete, bounded allowance rather than removing the cap, so an agent let go on
    /// once is still stopped eventually. With no ceiling at all, the step is what it
    /// has spent, which doubles it.
    public func ceilingToGoOn(under limits: CostLimits) -> Cost {
        let ceiling = ceiling(under: limits)
        let currency = ceiling?.currency ?? "USD"
        let already = costToDate[currency] ?? 0
        let step = ceiling?.amount ?? already
        return Cost(amount: already + step, currency: currency)
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
        // Queued has not begun, so it has no ending either (#362).
        if state == .queued && (endedReason != nil || archivedReason != nil) { return false }
        return true
    }
}

// MARK: Slim (051)

extension Agent {
    /// This agent without the lists that are nearly all of its record, for holding an
    /// archived agent nobody is reading. Everything the list, the counts and retirement
    /// need is still here.
    public func slimmed() -> Agent {
        var slim = self
        slim.advertisedOptions = []
        slim.availableCommands = []
        slim.plans = []
        slim.isSlim = true
        return slim
    }

    /// This agent with the lists put back from the record on disk. Only the lists come
    /// from `disk`: anything else changed in memory since it was slimmed is kept.
    public func madeWhole(from disk: Agent) -> Agent {
        var whole = self
        whole.advertisedOptions = disk.advertisedOptions
        whole.availableCommands = disk.availableCommands
        whole.plans = disk.plans
        whole.isSlim = false
        return whole
    }

    /// This agent as a lean `agents/list` sends it (#107): the slim lists, for a client's
    /// sessions column. Unlike `slimmed()` it is a copy on the wire, not a held state, so
    /// `isSlim` is not set; `listsLeftOut` is, so the reader knows the empty lists are not
    /// the agent's (#203).
    public func leaned() -> Agent {
        var lean = self
        lean.advertisedOptions = []
        lean.availableCommands = []
        lean.plans = []
        lean.listsLeftOut = true
        return lean
    }

    /// Whether the lists differ from `other`'s: what decides whether an `agent/changed`
    /// carries them (#203). Cheap when they have not moved: copies share their storage.
    public func listsDiffer(from other: Agent) -> Bool {
        advertisedOptions != other.advertisedOptions || availableCommands != other.availableCommands
            || plans != other.plans
    }

    /// This record as heard, keeping the lists `held` already had where it came without
    /// them: a lean list or a lean `agent/changed` must not empty the open chat's menus.
    ///
    /// A record that says it left them out keeps them all (#203). One that does not is the
    /// whole truth, an emptied plan included, unless all three are empty: a host from
    /// before #203 marked nothing, and a runtime never takes its options and commands back
    /// to nothing, so that is one that left them out.
    public func keepingLists(of held: Agent?) -> Agent {
        guard let held else { return self }
        var kept = self
        if listsLeftOut {
            kept.advertisedOptions = held.advertisedOptions
            kept.availableCommands = held.availableCommands
            kept.plans = held.plans
            kept.listsLeftOut = held.listsLeftOut
            return kept
        }
        guard advertisedOptions.isEmpty, availableCommands.isEmpty, plans.isEmpty else { return self }
        kept.advertisedOptions = held.advertisedOptions
        kept.availableCommands = held.availableCommands
        kept.plans = held.plans
        return kept
    }
}
