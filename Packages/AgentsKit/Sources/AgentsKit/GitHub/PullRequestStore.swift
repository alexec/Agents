import Foundation

/// What the daemon remembers about one of the person's pull requests (038 R12).
///
/// None of it is in the repository, for the reason `WorkflowState` isn't: it is the
/// app's own bookkeeping. Keyed by project folder and number.
public struct PullRequestRecord: Codable, Hashable, Sendable {
    public var folder: URL
    public var number: Int
    /// The last change key fired on, keyed `"<workflowID>/<trigger name>"` (R6).
    public var firedKeys: [String: String]
    /// The newest countable comment fired on, keyed by workflow id.
    public var commentWatermark: [String: Int]
    /// Babysitting runs in a row with nobody else acting in between (R8).
    public var consecutiveRuns: Int
    public var stoppedAt: Date?
    public var lastRunStartedAt: Date?
    public var lastOutcome: WorkflowOutcome?
    public var lastOutcomeWorkflowID: String?
    /// The heads `push_pull_request` pushed, the last 20: how babysitting's pushes are
    /// told from everybody else's.
    public var pushedOids: [String]
    /// The comments `reply_on_pull_request` made, the last 50.
    public var postedCommentIDs: [Int]

    static let pushedOidLimit = 20
    static let postedCommentLimit = 50

    public init(folder: URL, number: Int) {
        self.folder = Project.standardize(folder)
        self.number = number
        firedKeys = [:]
        commentWatermark = [:]
        consecutiveRuns = 0
        pushedOids = []
        postedCommentIDs = []
    }

    /// Read key by key, so that a field added later costs nothing already written.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        folder = Project.standardize(try c.decode(URL.self, forKey: .folder))
        number = try c.decode(Int.self, forKey: .number)
        firedKeys = try c.decodeIfPresent([String: String].self, forKey: .firedKeys) ?? [:]
        commentWatermark = try c.decodeIfPresent([String: Int].self, forKey: .commentWatermark) ?? [:]
        consecutiveRuns = try c.decodeIfPresent(Int.self, forKey: .consecutiveRuns) ?? 0
        stoppedAt = try c.decodeIfPresent(Date.self, forKey: .stoppedAt)
        lastRunStartedAt = try c.decodeIfPresent(Date.self, forKey: .lastRunStartedAt)
        lastOutcome = try? c.decodeIfPresent(WorkflowOutcome.self, forKey: .lastOutcome)
        lastOutcomeWorkflowID = try c.decodeIfPresent(String.self, forKey: .lastOutcomeWorkflowID)
        pushedOids = try c.decodeIfPresent([String].self, forKey: .pushedOids) ?? []
        postedCommentIDs = try c.decodeIfPresent([Int].self, forKey: .postedCommentIDs) ?? []
    }

    public mutating func notePushed(_ oid: String) {
        pushedOids = Array((pushedOids + [oid]).suffix(Self.pushedOidLimit))
    }

    public mutating func notePosted(_ id: Int) {
        postedCommentIDs = Array((postedCommentIDs + [id]).suffix(Self.postedCommentLimit))
    }
}

/// Everything in `pull-requests.json`.
struct PullRequestRecords: Codable, Sendable {
    var records: [PullRequestRecord] = []
    /// The last good list for each project, so a restarted daemon has something to show
    /// before its first refresh (FR-009).
    var lists: [PullRequestList] = []
    /// When each project last tried to refresh, by folder path, good or not (R3).
    var lastAttemptAt: [String: Date] = [:]

    init() {}

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        records = (try c.decodeIfPresent([Lossy<PullRequestRecord>].self, forKey: .records) ?? [])
            .compactMap(\.value)
        lists = (try c.decodeIfPresent([Lossy<PullRequestList>].self, forKey: .lists) ?? [])
            .compactMap(\.value)
        lastAttemptAt = try c.decodeIfPresent([String: Date].self, forKey: .lastAttemptAt) ?? [:]
    }

    func record(folder: URL, number: Int) -> PullRequestRecord? {
        let standardized = Project.standardize(folder)
        return records.first { $0.folder == standardized && $0.number == number }
    }

    mutating func update(folder: URL, number: Int, _ change: (inout PullRequestRecord) -> Void) {
        let standardized = Project.standardize(folder)
        if let index = records.firstIndex(where: { $0.folder == standardized && $0.number == number }) {
            change(&records[index])
        } else {
            var made = PullRequestRecord(folder: standardized, number: number)
            change(&made)
            records.append(made)
        }
    }

    /// Drop the records of pull requests that are no longer open (US1-5).
    mutating func keepOnly(_ numbers: Set<Int>, in folder: URL) {
        let standardized = Project.standardize(folder)
        records.removeAll { $0.folder == standardized && !numbers.contains($0.number) }
    }

    mutating func setList(_ list: PullRequestList?, for folder: URL) {
        let standardized = Project.standardize(folder)
        lists.removeAll { $0.folder == standardized }
        if let list { lists.append(list) }
    }
}

/// Where that is kept: one file, read whole and written whole, like `WorkflowStore`. A
/// file it cannot read is empty state. Losing it costs which changes already fired,
/// and at worst one repeat of each.
public struct PullRequestStore: Sendable {
    private let locations: StoreLocations

    public init(locations: StoreLocations) {
        self.locations = locations
    }

    func load() -> PullRequestRecords {
        guard let data = try? Data(contentsOf: locations.pullRequests),
              let records = try? StoreCoding.decoder.decode(PullRequestRecords.self, from: data) else {
            return PullRequestRecords()
        }
        return records
    }

    func save(_ records: PullRequestRecords) {
        guard let data = try? StoreCoding.encoder.encode(records) else { return }
        try? FileManager.default.createDirectory(at: locations.root, withIntermediateDirectories: true)
        try? data.write(to: locations.pullRequests, options: .atomic)
    }
}
