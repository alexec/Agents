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
    private var lineIndexes = LRUCache<UUID, TranscriptReader.Index>(limit: AgentStore.indexedTranscripts)
    /// Each read conversation's finished turns: where they start, and the summaries made
    /// so far.
    private var turnCache = LRUCache<UUID, Turns>(limit: AgentStore.indexedTranscripts)
    /// How many transcripts are indexed at once. Eight bytes a line, so an index is
    /// small, but the daemon lives for weeks and this is a memo, not a record. Past it the
    /// one read longest ago goes, not all of them: the seventeenth conversation read used
    /// to make the other sixteen rescan their whole files (#210).
    static let indexedTranscripts = 16

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
        load(agentIDs())
    }

    /// Every agent folder there is, by id, without opening any of them (051).
    public func agentIDs() -> [UUID] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: locations.agents, includingPropertiesForKeys: nil)) ?? []
        return contents.compactMap { UUID(uuidString: $0.lastPathComponent) }
    }

    /// These agents' records, as `loadAll` reads them. Start reads the archived ones
    /// from `archive.json` and only the rest from here (051, research R3).
    public func load(_ ids: [UUID]) -> (agents: [Agent], unreadable: [URL], mends: [UUID: Mend]) {
        var agents: [Agent] = []
        var unreadable: [URL] = []
        var mends: [UUID: Mend] = [:]
        for id in ids {
            do {
                let (agent, mend) = try load(id)
                agents.append(agent)
                if let mend { mends[id] = mend }
            } catch {
                // Left where it is, for a build that can read it, and said: an agent
                // that does not appear needs a reason somebody can find.
                DaemonLog.shared.write("could not read agent \(id), left on disk: \(error)")
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
        do {
            try handle.write(contentsOf: line)
        } catch {
            // A full disk can take part of the line. Kept, the handle would glue the next
            // entry to the fragment and lose both; let go, the next open ends it (073).
            closeTranscript(for: agentID)
            throw error
        }
    }

    public func appendAll(_ entries: [TranscriptEntry], for agentID: UUID) throws {
        for entry in entries { try append(entry, for: agentID) }
    }

    private func appendHandle(for agentID: UUID) throws -> FileHandle {
        if let handle = appendHandles[agentID] { return handle }
        let url = locations.transcript(agentID)
        try FileManager.default.createDirectory(at: locations.agent(agentID), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            _ = FileManager.default.createFile(atPath: url.path, contents: nil)
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

    /// Whether the agent's transcript is held open for appending. For a test (#163).
    func holdsTranscript(of agentID: UUID) -> Bool { appendHandles[agentID] != nil }

    /// Which conversations the transcript caches hold. For a test (#210).
    func heldTranscripts() -> (indexed: Set<UUID>, turns: Set<UUID>) {
        (Set(lineIndexes.keys), Set(turnCache.keys))
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
        lineIndexes.remove(id)
        historyMarks.remove(id)
        try check(.closeTranscript)
        try removeIfThere(locations.record(id))
        try check(.deleteRecord)
        try removeIfThere(locations.transcript(id))
        turnCache.remove(id)
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

    /// What is known of one conversation's turns.
    private struct Turns {
        /// The lines of the transcript that are a person's ask, up to `scanned`.
        var asks: [Int] = []
        var scanned = 0
        /// The summaries of the first turns, without a gap: what `turns.jsonl` holds.
        var known: [TurnSummary] = []
        /// Summaries of later turns, by their position, made for a page asked for
        /// before the ones ahead of them were (#91). Kept in memory only, and moved into
        /// `known` once the gap before them is filled.
        var later: [Int: TurnSummary] = [:]

        /// Where each turn starts: the first line, then every ask after it. The last
        /// is the turn still going.
        func starts(total: Int) -> [Int] {
            guard total > 0 else { return [] }
            return [0] + asks.drop { $0 == 0 }
        }
    }

    /// Finished turns, oldest first, and where the turn in progress starts.
    ///
    /// Where turns start is found by looking through the transcript's bytes for an ask,
    /// and decoding only the lines that might be one: a conversation of 100,000 entries
    /// costs a few hundred decodes rather than all of them (#91). A summary is made only
    /// for a turn on the page asked for, and `fillTurns` makes the rest. The ones from
    /// the first turn on, without a gap, are kept in `turns.jsonl`, so the next start
    /// reads them rather than makes them; one that no longer matches where its turn
    /// starts is made again.
    public func turns(for agentID: UUID, before: Int? = nil, limit: Int = 50) throws -> TurnsPage {
        let reader = TranscriptReader(url: locations.transcript(agentID))
        let index = try lineIndex(for: agentID, with: reader)
        var turns = try currentTurns(agentID, reader, index)
        let starts = turns.starts(total: index.count)
        let closed = max(0, starts.count - 1)

        // Never a backwards range, whatever is asked: Swift traps on one, and that
        // took the host down with every agent on it (#200).
        let end = max(0, min(before ?? closed, closed))
        let start = end - min(max(0, limit), end)
        try make((start..<end).filter { $0 >= turns.known.count && turns.later[$0] == nil },
                 in: &turns, starts: starts, reader, index)
        var page: [TurnSummary] = []
        page.reserveCapacity(end - start)
        for position in start..<end {
            if position < turns.known.count {
                // Older turn files kept only the last block, or no outcome (069). Restore
                // both for the requested page from the transcript, kept for this reader.
                let turn = turns.known[position]
                if turn.concise == nil || turn.outcome == nil {
                    let entries = try reader.entries(index, lines: turn.start..<turn.end).compactMap { $0 }
                    let fresh = TurnSummary.of(entries, start: turn.start)
                    turns.known[position].concise = fresh.concise
                    turns.known[position].outcome = fresh.outcome
                    turns.known[position].steps = fresh.steps
                }
                page.append(turns.known[position])
            } else if let summary = turns.later[position] {
                page.append(summary)
            }
        }
        try keepWhatFollows(&turns, for: agentID)

        turnCache.set(turns, for: agentID)
        return TurnsPage(turns: page, firstTurn: start, openStart: starts.last ?? 0)
    }

    /// Which lines of a transcript a session history reads (#210).
    public struct HistoryLines: Sendable, Equatable {
        /// The first turn, as ranges of lines to read in order: all of it, or as much
        /// of its start as fits.
        public var first: [Range<Int>] = []
        /// The latest turns, oldest first, each as ranges of lines: the whole turn, or
        /// its ask and as much of its end as fits.
        public var latest: [[Range<Int>]] = []
        /// Whole turns between the first and the latest that are not read.
        public var leftOut = 0
        /// The line of the last plan, wherever it is.
        public var plan: Int?
    }

    /// Where a session history's turns start and its last plan is, as far as `scanned`.
    /// Found by the bytes alone: a history starts a turn at every `userMessage`, the app's
    /// included, so unlike `turns` it decodes none of them (#210).
    private struct HistoryMarks {
        var asks: [Int] = []
        var lastPlan: Int?
        var scanned = 0
    }

    /// Kept apart from `turnCache`, so a lead reading its helpers never pushes out the
    /// conversations a window has open.
    private var historyMarks = LRUCache<UUID, HistoryMarks>(limit: AgentStore.indexedTranscripts)

    /// The first turn and the turns back from the end, until `bytes` of transcript are
    /// taken: a session history costs the same however long the session ran, where it
    /// used to decode every line from the first (#210).
    public func historyLines(for agentID: UUID, bytes: Int) throws -> HistoryLines {
        let reader = TranscriptReader(url: locations.transcript(agentID))
        let index = try lineIndex(for: agentID, with: reader)
        var marks = historyMarks.value(for: agentID) ?? HistoryMarks()
        // Read from some other transcript than this one: look again.
        if marks.scanned > index.count { marks = HistoryMarks() }
        // A key in the entry, never in a string: inside one its quotes are escaped.
        marks.asks += try reader.lines(containing: "\"userMessage\"", index, from: marks.scanned)
        if let plan = try reader.lines(containing: "\"planUpdated\"", index, from: marks.scanned).last {
            marks.lastPlan = plan
        }
        marks.scanned = index.count
        historyMarks.set(marks, for: agentID)

        guard index.count > 0 else { return HistoryLines() }
        let starts = [0] + marks.asks.drop { $0 == 0 }
        let ranges = zip(starts, starts.dropFirst() + [index.count]).map { $0..<$1 }
        func size(_ lines: Range<Int>) -> Int {
            lines.isEmpty ? 0 : Int(index.lineEnds[lines.upperBound - 1] - index.start(of: lines.lowerBound))
        }
        // A turn too long to take whole: its ask, then as much of its end as fits.
        func end(of turn: Range<Int>, within budget: Int) -> [Range<Int>] {
            let ask = turn.lowerBound..<turn.lowerBound + 1
            guard size(ask) <= budget else { return [] }
            var from = turn.upperBound
            while from > ask.upperBound, size((from - 1)..<turn.upperBound) + size(ask) <= budget { from -= 1 }
            return from < turn.upperBound ? [ask, from..<turn.upperBound] : [ask]
        }

        var result = HistoryLines(plan: marks.lastPlan)
        guard ranges.count > 1 else {
            result.first = size(ranges[0]) <= bytes ? [ranges[0]] : end(of: ranges[0], within: bytes)
            return result
        }
        // The first turn gets a quarter at most, and then its start: what was asked, and
        // how the work began.
        let firstBudget = bytes / 4
        if size(ranges[0]) <= firstBudget {
            result.first = [ranges[0]]
        } else {
            var to = ranges[0].lowerBound
            while to < ranges[0].upperBound, size(ranges[0].lowerBound..<(to + 1)) <= firstBudget { to += 1 }
            result.first = to > ranges[0].lowerBound ? [ranges[0].lowerBound..<to] : []
        }
        var left = bytes - result.first.reduce(0) { $0 + size($1) }
        var oldest = ranges.count
        for position in stride(from: ranges.count - 1, through: 1, by: -1) {
            let turn = ranges[position]
            if size(turn) <= left {
                result.latest.insert([turn], at: 0)
                left -= size(turn)
                oldest = position
            } else {
                // The latest turn is always read, as much of it as fits.
                if result.latest.isEmpty {
                    result.latest = [end(of: turn, within: left)]
                    oldest = position
                }
                break
            }
        }
        result.leftOut = oldest - 1
        return result
    }

    /// Make the summaries a page did not need, oldest first and one turn at a time, so
    /// `turns.jsonl` is whole by the next start and nothing waits long behind it (#91).
    /// Stops when there is no gap left, or the conversation is no longer in hand.
    public func fillTurns(for agentID: UUID) async {
        guard filling.insert(agentID).inserted else { return }
        defer { filling.remove(agentID) }
        while var turns = turnCache.peek(agentID) {
            let starts = turns.starts(total: turns.scanned)
            let position = turns.known.count
            guard position + 1 < starts.count else { return }
            do {
                if turns.later[position] == nil {
                    let reader = TranscriptReader(url: locations.transcript(agentID))
                    try make([position], in: &turns, starts: starts, reader,
                             lineIndex(for: agentID, with: reader))
                }
                try keepWhatFollows(&turns, for: agentID)
            } catch {
                return
            }
            turnCache.set(turns, for: agentID)
            await Task.yield()
        }
    }

    /// The conversations whose turns are being filled in.
    private var filling: Set<UUID> = []

    /// What is known of a conversation's turns, brought up to the end of its transcript.
    private func currentTurns(_ agentID: UUID, _ reader: TranscriptReader,
                              _ index: TranscriptReader.Index) throws -> Turns {
        let total = index.count
        var turns: Turns
        if let cached = turnCache.value(for: agentID) {
            turns = cached
        } else {
            turns = Turns(known: try readTurns(agentID))
            try checkKept(&turns, for: agentID, reader, index)
        }
        // Read from some other transcript than this one: look again.
        if turns.scanned > total {
            turns.asks = []
            turns.scanned = 0
            turns.later = [:]
        }
        let candidates = try reader.lines(containing: "\"userMessage\"", index, from: turns.scanned)
        for line in candidates where try isAsk(line, reader, index) {
            turns.asks.append(line)
        }
        turns.scanned = total

        // The kept summaries hold only while each still starts and ends where its turn
        // does. From the first that does not, they are made again.
        let starts = turns.starts(total: total)
        let closed = max(0, starts.count - 1)
        let valid = zip(turns.known.indices, turns.known).prefix {
            $0 < closed && $1.start == starts[$0] && $1.end == starts[$0 + 1]
        }.count
        if valid < turns.known.count {
            turns.known.removeLast(turns.known.count - valid)
            try writeTurns(turns.known, for: agentID)
        }
        turns.later = turns.later.filter {
            $0.key < closed && $0.value.start == starts[$0.key] && $0.value.end == starts[$0.key + 1]
        }
        return turns
    }

    /// Kept turns read back from `turns.jsonl`, checked against the transcript before
    /// they are trusted, so it is looked through only after the last of them.
    ///
    /// A turn holds while the line it starts on is still the entry it began with, and an
    /// ask is still where it ends. The last is checked first: a file for some other
    /// transcript, or one that counted lines differently, fails there. Only then is each
    /// looked at, for the first that does not hold, and the file cut back to before it.
    private func checkKept(_ turns: inout Turns, for agentID: UUID, _ reader: TranscriptReader,
                       _ index: TranscriptReader.Index) throws {
        let known = turns.known
        guard let last = known.last else { return }
        func begins(_ turn: TurnSummary) throws -> Bool {
            guard turn.start < index.count else { return false }
            return try reader.entries(index, lines: turn.start..<turn.start + 1).first??.id == turn.id
        }
        let joined = known[0].start == 0 && zip(known, known.dropFirst()).allSatisfy { $0.end == $1.start }
        var holding = known.count
        if !(try joined && begins(last) && isAsk(last.end, reader, index)) {
            holding = 0
            while holding < known.count,
                  known[holding].start == (holding == 0 ? 0 : known[holding - 1].end),
                  try begins(known[holding]) {
                holding += 1
            }
            if holding > 0, !(try isAsk(known[holding - 1].end, reader, index)) { holding -= 1 }
            turns.known = Array(known.prefix(holding))
            try writeTurns(turns.known, for: agentID)
        }
        turns.asks = turns.known.dropFirst().map(\.start)
        turns.scanned = turns.known.last?.end ?? 0
    }

    private func isAsk(_ line: Int, _ reader: TranscriptReader, _ index: TranscriptReader.Index) throws -> Bool {
        guard line < index.count, let entry = try reader.entries(index, lines: line..<line + 1).first ?? nil else {
            return false
        }
        return TranscriptItem.entry(entry).isPersonsAsk
    }

    /// The summaries of the turns at these positions, made from one read of the
    /// transcript, for `later`.
    private func make(_ positions: [Int], in turns: inout Turns, starts: [Int],
                      _ reader: TranscriptReader, _ index: TranscriptReader.Index) throws {
        guard let first = positions.first, let last = positions.last else { return }
        let entries = try reader.entries(index, lines: starts[first]..<starts[last + 1])
        // The transcript went (its agent deleted) or shrank while turns were being made in
        // the background: nothing to make, rather than slicing past what was read (#200).
        guard entries.count == starts[last + 1] - starts[first] else { throw TranscriptReader.Shrunk() }
        for position in positions {
            let lines = (starts[position] - starts[first])..<(starts[position + 1] - starts[first])
            var summary = TurnSummary.of(entries[lines].compactMap { $0 }, start: starts[position])
            // By the line, as `agents/transcript` counts: a line that did not decode is
            // still one.
            summary.end = starts[position + 1]
            turns.later[position] = summary
        }
    }

    /// The made summaries that follow the kept ones without a gap are kept too.
    private func keepWhatFollows(_ turns: inout Turns, for agentID: UUID) throws {
        var gained: [TurnSummary] = []
        while let next = turns.later.removeValue(forKey: turns.known.count) {
            turns.known.append(next)
            gained.append(next)
        }
        if !gained.isEmpty { try appendTurns(gained, for: agentID) }
    }

    private func readTurns(_ agentID: UUID) throws -> [TurnSummary] {
        guard let data = FileManager.default.contents(atPath: locations.turns(agentID).path) else { return [] }
        return data.split(separator: 0x0A).compactMap {
            try? StoreCoding.decoder.decode(TurnSummary.self, from: Data($0))
        }
    }

    /// The kept summaries, in place of what the file held.
    private func writeTurns(_ turns: [TurnSummary], for agentID: UUID) throws {
        let url = locations.turns(agentID)
        guard !turns.isEmpty else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        try encoded(turns).write(to: url, options: .atomic)
    }

    private func appendTurns(_ turns: [TurnSummary], for agentID: UUID) throws {
        let url = locations.turns(agentID)
        if !FileManager.default.fileExists(atPath: url.path) {
            _ = FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: encoded(turns))
    }

    private func encoded(_ turns: [TurnSummary]) throws -> Data {
        var data = Data()
        for turn in turns {
            data.append(try StoreCoding.encoder.encode(turn))
            data.append(0x0A)
        }
        return data
    }

    public func transcriptCount(for agentID: UUID) throws -> Int {
        try lineIndex(for: agentID, with: TranscriptReader(url: locations.transcript(agentID))).count
    }

    /// The transcript's line index, brought up to the end of the file.
    private func lineIndex(for agentID: UUID, with reader: TranscriptReader) throws -> TranscriptReader.Index {
        var index = lineIndexes.value(for: agentID) ?? TranscriptReader.Index()
        try reader.extend(&index)
        lineIndexes.set(index, for: agentID)
        return index
    }
}
