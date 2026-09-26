import Foundation

/// What the app remembers about a workflow that its file cannot say.
///
/// A few things, and the reason each is here rather than in the repository is the same:
/// writing it back would put the app's own bookkeeping into the project's history,
/// where nobody wants to review it. Archiving a workflow is not a commit.
public struct WorkflowState: Codable, Hashable, Sendable {
    public var folder: URL
    public var workflowID: String
    /// Put away by the person: off the project page and never fired again, with the
    /// file left where it is. This is the answer to an agent writing a workflow
    /// nobody asked for, and the reason writing one no longer asks first.
    public var isArchived: Bool
    /// The agent a `standing` workflow keeps. Adopted on its first fire, and replaced
    /// when the one it had is gone.
    public var standingAgentID: UUID?
    /// The standing agents a pull-request workflow keeps, one for each pull request
    /// (038 FR-017), by number.
    public var standingAgentIDs: [Int: UUID]
    /// What `nextDue` is measured against, so a fire that happened is not offered again.
    public var lastFiredAt: Date?
    /// The only evidence a refused fire leaves.
    public var lastOutcome: WorkflowOutcome?
    /// The event that caused `lastOutcome`, when an event did (042 FR-030).
    public var lastCausingEvent: EventPosition?
    /// SHA-256 of the file as the person last approved it. Kept here, outside the
    /// project, because the file itself is something an agent can write.
    public var approvedDigest: String?

    public var key: String { folder.path + "/" + workflowID }

    /// Read leniently, because a file written before archiving existed has no such key
    /// and losing every pause to a new field would be a poor trade.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        folder = Project.standardize(try c.decode(URL.self, forKey: .folder))
        workflowID = try c.decode(String.self, forKey: .workflowID)
        isArchived = try c.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
        standingAgentID = try c.decodeIfPresent(UUID.self, forKey: .standingAgentID)
        standingAgentIDs = try c.decodeIfPresent([Int: UUID].self, forKey: .standingAgentIDs) ?? [:]
        lastFiredAt = try c.decodeIfPresent(Date.self, forKey: .lastFiredAt)
        lastOutcome = try c.decodeIfPresent(WorkflowOutcome.self, forKey: .lastOutcome)
        lastCausingEvent = try c.decodeIfPresent(EventPosition.self, forKey: .lastCausingEvent)
        approvedDigest = try c.decodeIfPresent(String.self, forKey: .approvedDigest)
    }

    public init(folder: URL, workflowID: String, isArchived: Bool = false,
                standingAgentID: UUID? = nil, standingAgentIDs: [Int: UUID] = [:],
                lastFiredAt: Date? = nil, lastOutcome: WorkflowOutcome? = nil) {
        self.folder = Project.standardize(folder)
        self.workflowID = workflowID
        self.isArchived = isArchived
        self.standingAgentID = standingAgentID
        self.standingAgentIDs = standingAgentIDs
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
    /// This file already existed when `runs` was added, and `WorkflowStore.load()` reads
    /// a file it cannot decode as empty — so a synthesized decoder, which requires every
    /// key, would have read every file written before this one as nothing, and quietly
    /// un-archived every workflow the person had put away. One run that will not decode
    /// costs that run: a trigger from a newer build is not worth the archive beside it.
    ///
    /// In an extension, so the memberwise initialiser the rest of this file uses stays.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        states = try c.decodeIfPresent([WorkflowState].self, forKey: .states) ?? []
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
/// A missing or unreadable file is empty state rather than an error. Losing it loses
/// which workflows were archived and which agent a standing workflow had — every
/// workflow itself is still in the repository, which is the right thing to keep.
public struct WorkflowStore: Sendable {
    private let locations: StoreLocations

    public init(locations: StoreLocations) {
        self.locations = locations
    }

    func load() -> WorkflowRecords {
        guard let data = try? Data(contentsOf: locations.workflows),
              let records = try? StoreCoding.decoder.decode(WorkflowRecords.self, from: data) else {
            return WorkflowRecords()
        }
        return records
    }

    func save(_ records: WorkflowRecords) {
        guard let data = try? StoreCoding.encoder.encode(records) else { return }
        try? FileManager.default.createDirectory(at: locations.root, withIntermediateDirectories: true)
        try? data.write(to: locations.workflows, options: .atomic)
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
                         causingEvent: EventPosition? = nil) {
        update(folder: folder, workflowID: workflowID) { state in
            state.lastOutcome = outcome.following(state.lastOutcome)
            state.lastCausingEvent = causingEvent
            if case .ran = outcome { state.lastFiredAt = outcome.at }
        }
    }
}
