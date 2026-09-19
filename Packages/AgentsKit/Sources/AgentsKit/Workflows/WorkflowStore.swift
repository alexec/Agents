import Foundation

/// What the app remembers about a workflow that its file cannot say.
///
/// Three things, and the reason each is here rather than in the repository is the same:
/// writing it back would raise a confirmation every time an agent touched it and fill
/// the project's history with state nobody wants to review. Pausing a workflow is not
/// a commit.
public struct WorkflowState: Codable, Hashable, Sendable {
    public var folder: URL
    public var workflowID: String
    public var isPaused: Bool
    /// The agent a `standing` workflow keeps. Adopted on its first fire, and replaced
    /// when the one it had is gone.
    public var standingAgentID: UUID?
    /// What `nextDue` is measured against, so a fire that happened is not offered again.
    public var lastFiredAt: Date?
    /// The only evidence a refused fire leaves.
    public var lastOutcome: WorkflowOutcome?

    public var key: String { folder.path + "/" + workflowID }

    public init(folder: URL, workflowID: String, isPaused: Bool = false,
                standingAgentID: UUID? = nil, lastFiredAt: Date? = nil,
                lastOutcome: WorkflowOutcome? = nil) {
        self.folder = Project.standardize(folder)
        self.workflowID = workflowID
        self.isPaused = isPaused
        self.standingAgentID = standingAgentID
        self.lastFiredAt = lastFiredAt
        self.lastOutcome = lastOutcome
    }
}

/// Everything in the file, which is the states plus two things that belong to no single
/// workflow.
struct WorkflowRecords: Codable, Sendable {
    var states: [WorkflowState] = []
    /// Projects whose workflows are all held, as one switch.
    var pausedProjects: [URL] = []
    /// When the scheduler last looked. The heartbeat that makes a missed fire
    /// decidable: without it, "was anything listening at 9am?" has no honest answer.
    var lastTickAt: Date?
}

/// Where that state is kept.
///
/// One file, read whole and written whole, exactly as `ProjectStore` does it and for
/// the same reasons: it is tens of entries for one person, it changes when somebody
/// pauses something, and `cat` will show it to you.
///
/// A missing or unreadable file is empty state rather than an error. Losing it loses
/// which workflows were paused and which agent a standing workflow had — every
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
    mutating func record(_ outcome: WorkflowOutcome, folder: URL, workflowID: String) {
        update(folder: folder, workflowID: workflowID) { state in
            state.lastOutcome = outcome.following(state.lastOutcome)
            if case .ran = outcome { state.lastFiredAt = outcome.at }
        }
    }

    func isPaused(folder: URL) -> Bool {
        pausedProjects.contains(Project.standardize(folder))
    }

    mutating func setPaused(_ paused: Bool, folder: URL) {
        let standardized = Project.standardize(folder)
        if paused {
            if !pausedProjects.contains(standardized) { pausedProjects.append(standardized) }
        } else {
            pausedProjects.removeAll { $0 == standardized }
        }
    }
}
