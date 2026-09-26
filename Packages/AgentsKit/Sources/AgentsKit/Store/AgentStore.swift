import Foundation

/// The record on disk. The daemon is its only writer, and the app never reads the
/// directory: it asks the daemon. One reader of the truth, and no file locking between
/// processes to get wrong.
public actor AgentStore {
    public let locations: StoreLocations
    private var appendHandles: [UUID: FileHandle] = [:]
    /// Where each line of a transcript starts, for the ones a window has read.
    ///
    /// Grown rather than rebuilt: this actor is the only writer of those files, so
    /// the next page of a conversation costs a scan of what was appended since the
    /// last one, not of the whole file. A window flicking back through an hour of
    /// transcript used to have the daemon read the whole file for every page, with
    /// every append to every transcript waiting behind it.
    private var lineIndexes: [UUID: TranscriptReader.Index] = [:]
    /// How many transcripts are indexed at once. Eight bytes a line, so an index is
    /// small, but the daemon lives for weeks and this is a memo, not a record.
    private static let indexedTranscripts = 16

    public init(locations: StoreLocations = .default) throws {
        self.locations = locations
        try locations.createDirectories()
    }

    // MARK: What a record may say

    /// A record that breaks one of the four invariants, refused at the door.
    ///
    /// One case per rule, so the thrown value says which — a refusal that only said
    /// "inconsistent" would send the next person back to `isConsistent` to work out
    /// which of four things had gone wrong.
    public enum RecordRefused: Error, Hashable, Sendable {
        case archivedWithNoReason(UUID)
        case stoppedWithNoReason(UUID)
        case finishedWithoutEndTurn(UUID, EndedReason?)
        case startingWithAnEnding(UUID)
        /// A slim agent whose record could not be read to put its lists back (051).
        case slimWithoutRecord(UUID)

        /// For the log line, which is the only evidence a refusal leaves.
        var summary: String {
            switch self {
            case .archivedWithNoReason(let id):
                return "refused to save agent \(id): archived with no reason for it"
            case .stoppedWithNoReason(let id):
                return "refused to save agent \(id): stopped with no ending"
            case .finishedWithoutEndTurn(let id, let reason):
                return "refused to save agent \(id): finished, but ended \(reason.map(String.init(describing:)) ?? "nothing")"
            case .startingWithAnEnding(let id):
                return "refused to save agent \(id): starting, but carrying an ending"
            case .slimWithoutRecord(let id):
                return "refused to save agent \(id): slim, and its record could not be read to fill it in"
            }
        }
    }

    /// Which rule this record breaks, if any. The order matches `Agent.isConsistent`.
    static func refusal(for agent: Agent) -> RecordRefused? {
        if agent.state == .archived && agent.archivedReason == nil {
            return .archivedWithNoReason(agent.id)
        }
        if agent.state == .stopped && agent.endedReason == nil {
            return .stoppedWithNoReason(agent.id)
        }
        if agent.state == .finished && agent.endedReason != .endTurn {
            return .finishedWithoutEndTurn(agent.id, agent.endedReason)
        }
        if agent.state == .starting && (agent.endedReason != nil || agent.archivedReason != nil) {
            return .startingWithAnEnding(agent.id)
        }
        return nil
    }

    /// What was wrong with a record already on disk, and what was done about it.
    ///
    /// Mended rather than refused, which is the opposite of the rule on the way in and
    /// deliberately so: refusing a write catches the bug in the build that introduced
    /// it, which is the only cheap time. Refusing a *read* would lose the agent, and a
    /// person who cannot see an agent can do nothing about it.
    public enum Mend: Hashable, Sendable {
        case archivedWithNoReason
        case stoppedWithNoReason
        case finishedWithoutEndTurn(EndedReason?)
        case startingWithAnEnding

        /// What the person is told, in the transcript, in the app's voice.
        public var summary: String {
            switch self {
            case .archivedWithNoReason:
                return "This agent's record said it was archived but not that you archived it, which should not be possible. It has been put back as one you archived."
            case .stoppedWithNoReason:
                return "This agent's record said it had stopped but not how, which should not be possible. Its ending is recorded as one nothing vouched for."
            case .finishedWithoutEndTurn(let reason):
                let how = reason?.summary.map { " — \($0.lowercased())" } ?? ""
                return "This agent's record said it had finished, but its turn ended some other way\(how). It is recorded as stopped, which is what actually happened."
            case .startingWithAnEnding:
                return "This agent's record said it was still starting, which only ever lasts a moment, so the daemon holding it did not come back. It is recorded as having stopped when the daemon did."
            }
        }
    }

    /// Bring a record the rules forbid to one they allow, per the table in
    /// `contracts/record-and-wire.md`.
    static func mended(_ agent: Agent) -> (agent: Agent, mend: Mend)? {
        var fixed = agent
        switch refusal(for: agent) {
        case .archivedWithNoReason:
            fixed.archivedReason = .byUser
            return (fixed, .archivedWithNoReason)
        case .stoppedWithNoReason:
            fixed.endedReason = .unrecognised
            return (fixed, .stoppedWithNoReason)
        case .finishedWithoutEndTurn(_, let reason):
            // Keeping the reason it had: it is the one true thing about this record.
            fixed.state = .stopped
            if fixed.endedReason == nil { fixed.endedReason = .unrecognised }
            return (fixed, .finishedWithoutEndTurn(reason))
        case .startingWithAnEnding:
            // `starting` is only ever transient, so a record still in it is a daemon
            // that did not come back — which is an agent found dead, and is what
            // `recover` would have made of it had it been readable.
            fixed.state = .stopped
            fixed.endedReason = .daemonGone
            fixed.archivedReason = nil
            return (fixed, .startingWithAnEnding)
        // Never a refusal on the way in: it is about how a copy is saved, not what a
        // record says.
        case .slimWithoutRecord, nil:
            return nil
        }
    }

    // MARK: Records

    /// Written whole and atomically on every change, because a half-written record is
    /// an agent we can no longer account for.
    ///
    /// Refused if it breaks one of the four invariants, before anything is created or
    /// encoded, so nothing partial and nothing false reaches disk (FR-018, FR-019).
    /// `DaemonCore.saveQuietly` swallows the error with `try?`, which makes the log
    /// line below the only evidence a refusal happened — deliberately: a refused save
    /// is a bug in this app rather than news for the person, and taking the daemon
    /// down over one would lose the agents that are fine.
    public func save(_ agent: Agent) throws {
        if let refusal = Self.refusal(for: agent) {
            DaemonLog.shared.write(refusal.summary)
            throw refusal
        }
        var agent = agent
        // Retirement's two fields mean something only on an archived agent (051). A
        // path that forgets to clear them on the way out of archived is put right here
        // rather than refused: nothing else in the record depends on them.
        if agent.state != .archived {
            agent.archivedAt = nil
            agent.retirement = nil
        }
        // A slim copy never reaches the disk (051, research R2). Its lists are read back
        // from the record first, and without a record to read them from, the save is
        // refused: writing it as it is would throw them away for good.
        if agent.isSlim {
            do {
                let disk = try StoreCoding.decoder.decode(Agent.self, from: Data(contentsOf: locations.record(agent.id)))
                agent = agent.madeWhole(from: disk)
            } catch {
                DaemonLog.shared.write("refused to save agent \(agent.id): slim, and its record could not be read to fill it in")
                throw RecordRefused.slimWithoutRecord(agent.id)
            }
        }
        try FileManager.default.createDirectory(at: locations.agent(agent.id), withIntermediateDirectories: true)
        let data = try StoreCoding.encoder.encode(agent)
        try data.write(to: locations.record(agent.id), options: .atomic)
    }

    /// One record, mended if the rules require it.
    ///
    /// The `Mend` comes back rather than being acted on here, because the store does
    /// not have a transcript to write into. `DaemonCore.loadFromDisk` is what tells
    /// the person (FR-020).
    public func load(_ id: UUID) throws -> (agent: Agent, mend: Mend?) {
        let data = try Data(contentsOf: locations.record(id))
        let decoded = try StoreCoding.decoder.decode(Agent.self, from: data)
        guard let mended = Self.mended(decoded) else { return (decoded, nil) }
        return (mended.agent, mended.mend)
    }

    /// Every agent there has ever been, newest activity first.
    ///
    /// A record that will not decode is skipped rather than thrown, so one bad file
    /// cannot stop the daemon starting and losing sight of everything else. That is a
    /// different thing from a well-formed record in a forbidden state, which is mended
    /// and carried rather than skipped.
    public func loadAll() -> (agents: [Agent], unreadable: [URL], mends: [UUID: Mend]) {
        var agents: [Agent] = []
        var unreadable: [URL] = []
        var mends: [UUID: Mend] = [:]
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: locations.agents, includingPropertiesForKeys: nil)) ?? []
        for directory in contents {
            guard let id = UUID(uuidString: directory.lastPathComponent) else { continue }
            do {
                let (agent, mend) = try load(id)
                agents.append(agent)
                if let mend { mends[id] = mend }
            } catch {
                unreadable.append(locations.record(id))
            }
        }
        agents.sort { $0.lastActivityAt > $1.lastActivityAt }
        return (agents, unreadable, mends)
    }

    // MARK: Transcripts

    /// Appended, never rewritten. The handle is kept open because this is called for
    /// every chunk a runtime emits.
    public func append(_ entry: TranscriptEntry, for agentID: UUID) throws {
        let handle = try appendHandle(for: agentID)
        var line = try StoreCoding.encoder.encode(entry)
        line.append(0x0A)
        try handle.write(contentsOf: line)
    }

    public func appendAll(_ entries: [TranscriptEntry], for agentID: UUID) throws {
        for entry in entries { try append(entry, for: agentID) }
    }

    private func appendHandle(for agentID: UUID) throws -> FileHandle {
        if let handle = appendHandles[agentID] { return handle }
        let url = locations.transcript(agentID)
        try FileManager.default.createDirectory(at: locations.agent(agentID), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forUpdating: url)
        let end = try handle.seekToEnd()
        // A daemon killed mid-write leaves half a line. The next entry would be glued
        // to it and both lost to the reader, so the fragment is ended first — it stays
        // unreadable on its own, and everything after it reads.
        if end > 0 {
            try handle.seek(toOffset: end - 1)
            let last = try handle.read(upToCount: 1)
            try handle.seekToEnd()
            if last != Data([0x0A]) { try handle.write(contentsOf: Data([0x0A])) }
        }
        appendHandles[agentID] = handle
        return handle
    }

    /// Let go of an agent's handle: it is finished, or archived, or the daemon is going.
    public func closeTranscript(for agentID: UUID) {
        try? appendHandles.removeValue(forKey: agentID)?.close()
    }

    // MARK: Retiring (051)

    /// The steps of retiring an agent, after the tombstone, in the order they run. A
    /// daemon stopped between any two leaves either the whole agent or its tombstone,
    /// and `finishRetiring` completes the rest (FR-017).
    enum RetireStep: Int, CaseIterable {
        case tombstone, closeTranscript, deleteRecord, deleteTranscript, removeFolder
    }

    /// For the tests: stop after this step, as a kill would.
    var failAfter: RetireStep?
    func stop(after step: RetireStep?) { failAfter = step }
    struct Stopped: Error {}

    /// Retire one agent: write its tombstone and sync it, then delete what the app kept
    /// for it. Nothing is deleted if the tombstone cannot be written.
    public func retire(_ tombstone: Tombstone, into retired: RetiredStore) throws {
        try retired.append(tombstone)
        try check(.tombstone)
        try deleteRetiredFiles(tombstone.id)
    }

    /// Finish what a stopped retire began: for each of these ids that still has a
    /// folder, the tombstone is already written, so what is left is deleting.
    public func finishRetiring(_ ids: some Sequence<UUID>) {
        for id in ids where FileManager.default.fileExists(atPath: locations.agent(id).path) {
            DaemonLog.shared.write("finishing the retirement of \(id), cut off last time")
            try? deleteRetiredFiles(id)
        }
    }

    /// Delete what the app kept for an agent whose tombstone is already written. The
    /// daemon's path: it writes the tombstone itself, and does the worktree in between.
    public func deleteRetired(_ id: UUID) throws {
        try deleteRetiredFiles(id)
    }

    /// The record first, then the transcript, then the folder: a folder with no record
    /// is one `loadAll` cannot read, so a half-deleted agent is never listed as whole.
    private func deleteRetiredFiles(_ id: UUID) throws {
        closeTranscript(for: id)
        lineIndexes.removeValue(forKey: id)
        try check(.closeTranscript)
        try removeIfThere(locations.record(id))
        try check(.deleteRecord)
        try removeIfThere(locations.transcript(id))
        try check(.deleteTranscript)
        try removeIfThere(locations.agent(id))
        try check(.removeFolder)
    }

    private func check(_ step: RetireStep) throws {
        if failAfter == step { throw Stopped() }
    }

    private func removeIfThere(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    public func closeAll() {
        for (_, handle) in appendHandles { try? handle.close() }
        appendHandles.removeAll()
    }

    /// A page of a transcript, newest last. Never the whole thing.
    public func transcript(for agentID: UUID, before: Int? = nil, limit: Int = 200) throws -> TranscriptPage {
        let reader = TranscriptReader(url: locations.transcript(agentID))
        let index = try lineIndex(for: agentID, with: reader)
        return try reader.page(index, before: before, limit: limit)
    }

    public func transcriptCount(for agentID: UUID) throws -> Int {
        try lineIndex(for: agentID, with: TranscriptReader(url: locations.transcript(agentID))).count
    }

    /// The transcript's line index, brought up to the end of the file.
    private func lineIndex(for agentID: UUID, with reader: TranscriptReader) throws -> TranscriptReader.Index {
        var index = lineIndexes[agentID] ?? TranscriptReader.Index()
        try reader.extend(&index)
        if lineIndexes[agentID] == nil, lineIndexes.count >= Self.indexedTranscripts {
            lineIndexes.removeAll(keepingCapacity: true)
        }
        lineIndexes[agentID] = index
        return index
    }
}
