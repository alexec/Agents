import Foundation
import AgentsKitCore

/// Where the time of running chats went, by runtime (#852): the history behind the Time
/// page. `TimeHistory` says what is kept and why it stays bounded.
///
/// Held in memory once read, as `UsageLedger` is: `note` and `record` change memory,
/// `flush` writes. The daemon is the only writer of this file while it runs.
///
/// Each running turn's marks are kept here as the daemon records its entries, and banked
/// when the turn ends. A turn cut off by the daemon stopping loses what it had not
/// banked. A turn of more than `marksKept` new marks is banked in parts, so memory stays
/// bounded however long a turn runs.
///
/// The first run with no file is seeded once, in the background, from the transcripts
/// still on disk, before this ledger was made, so no turn is counted twice.
public final class TimeLedger: @unchecked Sendable {
    private let locations: StoreLocations
    private let calendar: Calendar
    private let lock = NSLock()
    private var held: TimeHistory?
    private var unwritten = false
    /// Each running turn's marks, by agent, since the turn began or was last banked, and
    /// how many of them were carried over from the last part banked.
    private var turns: [UUID: (marks: [TimeMark], carried: Int)] = [:]
    private let madeAt: Date
    private let needsSeed: Bool

    /// The most marks a turn holds before what it has is banked.
    static let marksKept = 2_000

    public init(locations: StoreLocations, now: Date = Date(), calendar: Calendar = .current) {
        self.locations = locations
        self.calendar = calendar
        self.madeAt = now
        self.needsSeed = !FileManager.default.fileExists(atPath: locations.timeHistory.path)
    }

    /// Note an entry as it is recorded. Returns whether a turn ended and was banked, so
    /// the caller knows to flush.
    @discardableResult
    public func note(_ entry: TranscriptEntry, agentID: UUID, runtime: String) -> Bool {
        guard let mark = TimeMark.of(entry) else { return false }
        return lock.withLock {
            var (marks, carried) = turns[agentID] ?? ([], 0)
            if case .state(let state, _) = mark, state == .running, marks.isEmpty {
                turns[agentID] = ([mark], 0)
                return false
            }
            // Nothing is counted outside a turn.
            guard !marks.isEmpty else { return false }
            marks.append(mark)
            if case .state(let state, _) = mark, state != .running, state != .waitingOnUser {
                bankLocked(TimeMark.segments(marks), runtime: runtime, endsTurn: true)
                turns[agentID] = nil
                return true
            }
            if marks.count - carried >= Self.marksKept {
                let (segments, carry) = TimeMark.split(marks)
                bankLocked(segments, runtime: runtime, endsTurn: false)
                (marks, carried) = (carry, carry.count)
            }
            turns[agentID] = (marks, carried)
            return false
        }
    }

    /// Forget a turn that will not end in an entry: its agent was removed.
    public func forget(_ agentID: UUID) {
        lock.withLock { _ = turns.removeValue(forKey: agentID) }
    }

    private func bankLocked(_ segments: [TimeSegment], runtime: String, endsTurn: Bool) {
        guard !segments.isEmpty else { return }
        var history = readLocked()
        if endsTurn {
            history.add(segments, runtime: runtime, calendar: calendar)
        } else {
            for segment in segments {
                history.add(segment.kind, from: segment.start, to: segment.end, runtime: runtime, calendar: calendar)
            }
        }
        held = history
        unwritten = true
    }

    /// Write what was banked, if anything. A failed write stays unwritten.
    public func flush() throws {
        try lock.withLock {
            guard unwritten, var history = held else { return }
            history.prune()
            held = history
            try StoreFile.write(try StoreCoding.encoder.encode(history), to: locations.timeHistory)
            unwritten = false
        }
    }

    /// What is kept, stamped with the host's hour now.
    public func history(at now: Date) -> TimeHistory {
        lock.withLock {
            var history = readLocked()
            history.prune()
            history.now = UsageHistory.hourStamp(for: now, calendar: calendar)
            return history
        }
    }

    /// Seed a first run from the transcripts on disk, then write. Called once, off the
    /// daemon's actor. Does nothing when the file was already there.
    public func seedIfNeeded() {
        guard needsSeed else { return }
        let seed = Self.seed(agents: locations.agents, before: madeAt, calendar: calendar)
        lock.withLock {
            var history = readLocked()
            for (hour, runtimes) in seed.hours {
                for (runtime, bucket) in runtimes {
                    history.hours[hour, default: [:]][runtime, default: TimeBucket()].add(bucket)
                }
            }
            for (day, runtimes) in seed.days {
                for (runtime, bucket) in runtimes {
                    history.days[day, default: [:]][runtime, default: TimeBucket()].add(bucket)
                }
            }
            held = history
            unwritten = true
        }
        try? flush()
    }

    private func readLocked() -> TimeHistory {
        if let held { return held }
        let read = StoreFile.load(TimeHistory.self, at: locations.timeHistory, empty: TimeHistory(),
                                  meaning: "the Time page starts again from nothing")
        held = read
        return read
    }

    // MARK: Seed

    private struct AgentRuntime: Decodable { var runtimeID: String }

    /// The keys of the entries that make a mark. Only lines holding one are decoded.
    private static let markers = ["\"stateChanged\"", "\"toolCall\"", "\"toolCallUpdate\"", "\"elicitationAsked\"",
                                  "\"elicitationAnswered\"", "\"permissionAsked\"", "\"permissionAnswered\""]
        .map { Data($0.utf8) }
    private static let updateMarker = Data("\"toolCallUpdate\"".utf8)
    private static let endings = ["\"status\":\"completed\"", "\"status\":\"failed\""].map { Data($0.utf8) }

    /// Every turn in every transcript still on disk, before `cutoff` and within the days
    /// kept, by runtime.
    static func seed(agents: URL, before cutoff: Date, calendar: Calendar) -> TimeHistory {
        var history = TimeHistory()
        let oldest = calendar.date(byAdding: .day, value: -UsageHistory.daysKept, to: cutoff) ?? .distantPast
        let folders = (try? FileManager.default.contentsOfDirectory(at: agents, includingPropertiesForKeys: nil)) ?? []
        for folder in folders {
            guard let record = try? Data(contentsOf: folder.appendingPathComponent("agent.json")),
                  let runtime = try? StoreCoding.decoder.decode(AgentRuntime.self, from: record).runtimeID,
                  let transcript = try? Data(contentsOf: folder.appendingPathComponent("transcript.jsonl"),
                                             options: .mappedIfSafe) else { continue }
            var marks: [TimeMark] = []
            for line in transcript.split(separator: UInt8(ascii: "\n"))
            where markers.contains(where: { line.range(of: $0) != nil }) {
                // Most updates are a call still going; only an ending makes a mark.
                if line.range(of: updateMarker) != nil, !endings.contains(where: { line.range(of: $0) != nil }) {
                    continue
                }
                guard let entry = try? StoreCoding.decoder.decode(TranscriptEntry.self, from: Data(line)),
                      entry.at < cutoff, let mark = TimeMark.of(entry) else { continue }
                marks.append(mark)
            }
            // Cut into turns at each start of running from rest, as `note` does.
            var turn: [TimeMark] = []
            func bank() {
                let segments = TimeMark.segments(turn).filter { $0.start >= oldest }
                history.add(segments, runtime: runtime, calendar: calendar)
                turn = []
            }
            for mark in marks {
                if case .state(let state, _) = mark {
                    if state == .running, turn.isEmpty { turn = [mark]; continue }
                    guard !turn.isEmpty else { continue }
                    turn.append(mark)
                    if state != .running, state != .waitingOnUser { bank() }
                } else if !turn.isEmpty {
                    turn.append(mark)
                }
            }
            // A turn the transcript never ended, the daemon having stopped mid-turn,
            // counts as far as its last mark.
            if !turn.isEmpty { bank() }
        }
        // The hours kept are the last 168 before the cutoff; older stretches stay in days.
        let lastHour = UsageHistory.hourStamp(for: cutoff, calendar: calendar)
        let firstHour = UsageHistory.hourStamp(
            for: cutoff.addingTimeInterval(-Double(UsageHistory.hoursKept) * 3600), calendar: calendar)
        history.hours = history.hours.filter { $0.key > firstHour && $0.key <= lastHour }
        history.prune()
        return history
    }
}
