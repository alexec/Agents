import Foundation

/// One trigger a cooldown is holding, with what `fire` needs to run it later.
public struct HeldWorkflowFire: Codable, Hashable, Sendable {
    public var trigger: WorkflowTrigger
    public var triggeringAgentID: UUID?
    public var depth: Int
    public var causingEvent: EventPosition?
    public var heldAt: Date

    public init(trigger: WorkflowTrigger, triggeringAgentID: UUID?, depth: Int,
                causingEvent: EventPosition?, heldAt: Date) {
        self.trigger = trigger
        self.triggeringAgentID = triggeringAgentID
        self.depth = depth
        self.causingEvent = causingEvent
        self.heldAt = heldAt
    }
}

/// What the app remembers about a workflow that its file cannot say.
///
/// Its history on this host: runs, outcomes, a held trigger, the standing agent, and
/// what the person approved. Whether it is turned off or archived is not here: since
/// #125 that is the file's own `enabled:` and `archived:`, so it travels with the
/// project to every clone and host.
public struct WorkflowState: Codable, Hashable, Sendable {
    public var folder: URL
    public var workflowID: String
    /// Who turned it off on this host, for the page's reason and for the rule that an
    /// agent may turn back on only what an agent turned off (#100, #124). Held against
    /// `offDigest`: once the file is no longer the one this host wrote, the reason is
    /// somebody else's and reads as `.file`.
    public var offBy: WorkflowOffReason?
    /// SHA-256 of the file when `offBy` was recorded, kept current through the app's
    /// own edits of the file.
    public var offDigest: String?
    /// The switch and archive as kept here before #125, read only to write them into
    /// the file once (`migrateWorkflowSwitchesToFiles`), then cleared. Kept until that
    /// write succeeds, so a project folder that is away for now is migrated later.
    public var legacy: LegacySwitches?

    /// What `workflows.json` said about a workflow's switch and archive before #125.
    public struct LegacySwitches: Codable, Hashable, Sendable {
        public var isArchived = false
        public var isDisabled = false
        public var disabledByAgent = false
        public var enabledChosen = false
        public var writtenOffByAgent = false

        /// Whether it was off, by the rule of the day: the switch as last moved, or,
        /// before anybody moved it, off if either the app or the file said so.
        func isOff(fileSaysOff: Bool) -> Bool {
            enabledChosen ? isDisabled : (isDisabled || fileSaysOff)
        }

        /// Who turned it off, as `offBy` records it; nil for its file.
        var offBy: WorkflowOffReason? {
            if writtenOffByAgent { return .writtenByAgent }
            if disabledByAgent { return .agent }
            return enabledChosen ? .person : nil
        }

        var isEmpty: Bool { self == LegacySwitches() }
    }
    /// The agent a `standing` workflow keeps. Adopted on its first fire, and replaced
    /// when the one it had is gone.
    public var standingAgentID: UUID?
    /// What `nextDue` is measured against, so a fire that happened is not offered again.
    public var lastFiredAt: Date?
    /// What set off the run at `lastFiredAt` (#98).
    public var lastFiredBy: WorkflowCause?
    /// The only evidence a refused fire leaves.
    public var lastOutcome: WorkflowOutcome?
    /// The event that caused `lastOutcome`, when an event did (042 FR-030).
    public var lastCausingEvent: EventPosition?
    /// SHA-256 of the file as the person last approved it. Kept here, outside the
    /// project, because the file itself is something an agent can write.
    public var approvedDigest: String?
    /// The trigger its cooldown is holding (#103): the latest to arrive while it was
    /// cooling down or running, replaced by each one after it, and run once when the
    /// cooldown ends. Kept here so a restart in between still runs it.
    public var heldFire: HeldWorkflowFire?

    public var key: String { folder.path + "/" + workflowID }

    /// Whether `workflow` is turned off: its file's `enabled: false` (#125).
    public static func isOff(_ workflow: Workflow) -> Bool {
        workflow.isOff
    }

    /// Why it is off, for its page (#124), or `nil` while it is on. `digest` is the
    /// file's as it is now: a reason recorded against another version of the file is
    /// not this one's.
    public static func offReason(_ workflow: Workflow, _ state: WorkflowState?,
                                 digest: String?) -> WorkflowOffReason? {
        guard workflow.isOff else { return nil }
        if let by = state?.offBy, digest != nil, state?.offDigest == digest { return by }
        return .file
    }

    enum CodingKeys: String, CodingKey {
        case folder, workflowID, offBy, offDigest, standingAgentID, lastFiredAt, lastFiredBy
        case lastOutcome, lastCausingEvent, approvedDigest, heldFire
        // Before #125.
        case isArchived, isDisabled, disabledByAgent, enabledChosen, writtenOffByAgent
    }

    /// Read leniently, because a file written before a field existed has no such key
    /// and losing every workflow's history to a new field would be a poor trade.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        folder = Project.standardize(try c.decode(URL.self, forKey: .folder))
        workflowID = try c.decode(String.self, forKey: .workflowID)
        offBy = (try? c.decodeIfPresent(WorkflowOffReason.self, forKey: .offBy)) ?? nil
        offDigest = try c.decodeIfPresent(String.self, forKey: .offDigest)
        var legacy = LegacySwitches()
        legacy.isArchived = try c.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
        legacy.isDisabled = try c.decodeIfPresent(Bool.self, forKey: .isDisabled) ?? false
        legacy.disabledByAgent = try c.decodeIfPresent(Bool.self, forKey: .disabledByAgent) ?? false
        legacy.enabledChosen = try c.decodeIfPresent(Bool.self, forKey: .enabledChosen) ?? false
        legacy.writtenOffByAgent = try c.decodeIfPresent(Bool.self, forKey: .writtenOffByAgent) ?? false
        self.legacy = legacy.isEmpty ? nil : legacy
        standingAgentID = try c.decodeIfPresent(UUID.self, forKey: .standingAgentID)
        lastFiredAt = try c.decodeIfPresent(Date.self, forKey: .lastFiredAt)
        lastFiredBy = (try? c.decodeIfPresent(WorkflowCause.self, forKey: .lastFiredBy)) ?? nil
        // An outcome this version no longer has — a pull-request refusal from before
        // GitHub support was removed (09-28, after the #58 cut-off) — is forgotten
        // rather than losing the whole state. Also how a newer build's outcome reads.
        lastOutcome = (try? c.decodeIfPresent(WorkflowOutcome.self, forKey: .lastOutcome)) ?? nil
        lastCausingEvent = try c.decodeIfPresent(EventPosition.self, forKey: .lastCausingEvent)
        approvedDigest = try c.decodeIfPresent(String.self, forKey: .approvedDigest)
        heldFire = try? c.decodeIfPresent(HeldWorkflowFire.self, forKey: .heldFire)
    }

    /// Written in the old keys while a migration is still owed, so an older build
    /// reading this file back still finds its switches.
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(folder, forKey: .folder)
        try c.encode(workflowID, forKey: .workflowID)
        try c.encodeIfPresent(offBy, forKey: .offBy)
        try c.encodeIfPresent(offDigest, forKey: .offDigest)
        if let legacy {
            try c.encode(legacy.isArchived, forKey: .isArchived)
            try c.encode(legacy.isDisabled, forKey: .isDisabled)
            try c.encode(legacy.disabledByAgent, forKey: .disabledByAgent)
            try c.encode(legacy.enabledChosen, forKey: .enabledChosen)
            try c.encode(legacy.writtenOffByAgent, forKey: .writtenOffByAgent)
        }
        try c.encodeIfPresent(standingAgentID, forKey: .standingAgentID)
        try c.encodeIfPresent(lastFiredAt, forKey: .lastFiredAt)
        try c.encodeIfPresent(lastFiredBy, forKey: .lastFiredBy)
        try c.encodeIfPresent(lastOutcome, forKey: .lastOutcome)
        try c.encodeIfPresent(lastCausingEvent, forKey: .lastCausingEvent)
        try c.encodeIfPresent(approvedDigest, forKey: .approvedDigest)
        try c.encodeIfPresent(heldFire, forKey: .heldFire)
    }

    public init(folder: URL, workflowID: String,
                standingAgentID: UUID? = nil,
                lastFiredAt: Date? = nil, lastOutcome: WorkflowOutcome? = nil) {
        self.folder = Project.standardize(folder)
        self.workflowID = workflowID
        self.standingAgentID = standingAgentID
        self.lastFiredAt = lastFiredAt
        self.lastOutcome = lastOutcome
    }
}

/// Everything in the file, which is the states plus two things that belong to no single
/// workflow.
struct WorkflowRecords: Codable, Sendable {
    var states: [WorkflowState] = []
    /// When the scheduler last looked. The heartbeat that makes a missed fire
    /// decidable: without it, "was anything listening at 9am?" has no honest answer.
    var lastTickAt: Date?
    /// The runs in flight when this was written (025).
    ///
    /// The one piece of workflow bookkeeping that used to live only in memory. A daemon
    /// that went while a run was going picked its agent back up and let it finish — and
    /// then nothing waiting on that workflow's completion was told, because the run it
    /// would have been told about had gone, and the depth that stops a chain looping went
    /// with it. Written wherever `DaemonCore.workflowRuns` moves.
    var runs: [WorkflowRun] = []
    /// When approval began. Every workflow file present then was approved as it stood,
    /// so the upgrade stops nothing; any file new or changed after it waits.
    var approvalsBegan: Date?
    /// Read from a file that is there and could not be read (#169): approval has begun,
    /// nothing is approved, and the file is left as it is. Not written.
    var unreadable = false

    /// How long a run is believed. A run in flight for a week is a run whose agent will
    /// not be finishing, and holding its workflow any longer only stops it firing.
    static let runHorizon: TimeInterval = 7 * 24 * 60 * 60

    enum CodingKeys: String, CodingKey {
        case states, lastTickAt, runs, approvalsBegan
    }
}

extension WorkflowRecords {
    /// Read leniently, key by key.
    ///
    /// This file already existed when `runs` was added, and a file that cannot be decoded
    /// approves nothing (#169) — so a synthesized decoder, which requires every key,
    /// would have read every file written before this one as unreadable. One run or state
    /// that will not decode costs that one: a trigger or an outcome from a newer build is
    /// not worth every workflow's history beside it.
    ///
    /// In an extension, so the memberwise initialiser the rest of this file uses stays.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        states = (try c.decodeIfPresent([Lossy<WorkflowState>].self, forKey: .states) ?? [])
            .compactMap(\.value)
        lastTickAt = try c.decodeIfPresent(Date.self, forKey: .lastTickAt)
        runs = (try c.decodeIfPresent([Lossy<WorkflowRun>].self, forKey: .runs) ?? [])
            .compactMap(\.value)
        approvalsBegan = try c.decodeIfPresent(Date.self, forKey: .approvalsBegan)
    }
}

/// Where that state is kept.
///
/// One file, read whole and written whole, exactly as `ProjectStore` does it and for
/// the same reasons: it is tens of entries for one person, it changes when somebody
/// pauses something, and `cat` will show it to you.
///
/// A missing file is empty state, approval not yet begun. A file that is there and
/// cannot be read approves nothing and is left as it is (#169, `ApprovalFile`): every
/// workflow waits for the person, and only their Approve replaces the file, keeping a
/// copy of the old one. Every workflow, and whether it is off or archived, is still in
/// the repository.
public struct WorkflowStore: Sendable {
    private let locations: StoreLocations

    public init(locations: StoreLocations) {
        self.locations = locations
    }

    var file: URL { locations.workflows }

    func load() -> WorkflowRecords {
        switch ApprovalFile.read(WorkflowRecords.self, at: locations.workflows) {
        case .missing: return WorkflowRecords()
        case .read(let records): return records
        case .unreadable: return WorkflowRecords(approvalsBegan: Date(), unreadable: true)
        }
    }

    /// `replacing` is the person's own act, the only write that replaces a file that
    /// could not be read; any other write leaves that file alone.
    func save(_ records: WorkflowRecords, replacing: Bool = false) throws {
        let data = try StoreCoding.encoder.encode(records)
        try ApprovalFile.write(data, to: locations.workflows, overUnreadable: records.unreadable,
                               replacing: replacing)
    }
}

extension WorkflowRecords {
    func state(folder: URL, workflowID: String) -> WorkflowState? {
        let standardized = Project.standardize(folder)
        return states.first { $0.folder == standardized && $0.workflowID == workflowID }
    }

    mutating func update(folder: URL, workflowID: String,
                         _ change: (inout WorkflowState) -> Void) {
        let standardized = Project.standardize(folder)
        if let index = states.firstIndex(where: {
            $0.folder == standardized && $0.workflowID == workflowID
        }) {
            change(&states[index])
        } else {
            var made = WorkflowState(folder: standardized, workflowID: workflowID)
            change(&made)
            states.append(made)
        }
    }

    /// Record what a fire produced, counting a repeat of the same refusal rather than
    /// listing it again. This is what keeps a fortnight away to one line.
    mutating func record(_ outcome: WorkflowOutcome, folder: URL, workflowID: String,
                         causingEvent: EventPosition? = nil, cause: WorkflowCause? = nil) {
        update(folder: folder, workflowID: workflowID) { state in
            state.lastOutcome = outcome.following(state.lastOutcome)
            state.lastCausingEvent = causingEvent
            if case .ran = outcome {
                state.lastFiredAt = outcome.at
                state.lastFiredBy = cause
            }
        }
    }
}
