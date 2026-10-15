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
    /// The agents in a turn that wait for the person, and what each waits on: its state,
    /// an ask, or an asking tool (#985).
    private var waiting: [UUID: Set<String>] = [:]
    /// Since when agents have run with none waiting for the person, while they do.
    private var clearSince: Date?
    /// The agents that ran a turn today. Only in memory: after a restart the day's count
    /// is the larger of what was written and what is seen again, never counted twice.
    private var seen: (day: String, agents: Set<UUID>) = ("", [])
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
            let ended = noteTurnLocked(mark, agentID: agentID, runtime: runtime)
            noteRecapLocked(mark, agentID: agentID)
            return ended
        }
    }

    private func noteTurnLocked(_ mark: TimeMark, agentID: UUID, runtime: String) -> Bool {
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
            waiting[agentID] = nil
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

    // MARK: Recap (#985)

    /// After `noteTurnLocked`: which agents wait for the person, the agents in a turn at
    /// once, the agents run today, and the stretches with nobody waited for.
    private func noteRecapLocked(_ mark: TimeMark, agentID: UUID) {
        let day = UsageChart.dayStamp(mark.at, calendar: calendar)
        if turns[agentID] != nil {
            var open = waiting[agentID] ?? []
            switch mark {
            case .state(let state, _):
                if state == .waitingOnUser { open.insert("state") } else { open.remove("state") }
            case .toolStarted(let id, let name, _):
                if TimeMark.kind(ofTool: name) == .person { open.insert("tool:" + id) }
            case .toolEnded(let id, _):
                open.remove("tool:" + id)
            case .askOpened(let id, _):
                open.insert("ask:" + id)
            case .askClosed(let id, _):
                if let id { open.remove("ask:" + id) } else { open = open.filter { !$0.hasPrefix("ask:") } }
            }
            waiting[agentID] = open.isEmpty ? nil : open

            if case .state(.running, _) = mark, turns[agentID]?.marks.count == 1 {
                if seen.day != day { seen = (day, []) }
                seen.agents.insert(agentID)
                let (count, atOnce) = (seen.agents.count, turns.count)
                var history = readLocked()
                history.changeRecap(day) {
                    $0.agents = max($0.agents, count)
                    $0.peakAgents = max($0.peakAgents, atOnce)
                }
                held = history
                unwritten = true
            }
        }
        let clear = !turns.isEmpty && waiting.isEmpty
        if clear, clearSince == nil {
            clearSince = mark.at
        } else if !clear, let since = clearSince {
            clearSince = nil
            bankClearLocked(from: since, to: mark.at)
        }
    }

    /// A stretch with nobody waited for, counted on the day it ended.
    private func bankClearLocked(from start: Date, to end: Date) {
        let seconds = end.timeIntervalSince(start)
        guard seconds > 0 else { return }
        var history = readLocked()
        history.changeRecap(UsageChart.dayStamp(end, calendar: calendar)) {
            $0.longestClear = max($0.longestClear, seconds)
        }
        held = history
        unwritten = true
    }

    /// What `gh` said about the pull requests merged on these days. Returns what it adds
    /// to the last count, for the Blob to celebrate (#986).
    @discardableResult
    public func setPRsMerged(_ counts: [String: Int], on days: [String], today: String = "") -> PRsLanded? {
        lock.withLock {
            var history = readLocked()
            let landed = history.landed(counts, on: days, today: today)
            history.setPRsMerged(counts, on: days)
            held = history
            unwritten = true
            return landed
        }
    }

    /// Whether `gh` has answered for any day yet: the first ask goes back as far as is kept.
    public var hasPRsMerged: Bool {
        lock.withLock { readLocked().recap.values.contains { $0.prsMerged != nil } }
    }

    /// Forget a turn that will not end in an entry: its agent was removed.
    public func forget(_ agentID: UUID) {
        lock.withLock {
            turns.removeValue(forKey: agentID)
            waiting.removeValue(forKey: agentID)
        }
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

    /// What is kept, stamped with the host's hour now, with a stretch still going
    /// counted as far as now.
    public func history(at now: Date) -> TimeHistory {
        lock.withLock {
            var history = readLocked()
            history.prune()
            history.now = UsageHistory.hourStamp(for: now, calendar: calendar)
            if let since = clearSince, now > since {
                history.changeRecap(UsageChart.dayStamp(now, calendar: calendar)) {
                    $0.longestClear = max($0.longestClear, now.timeIntervalSince(since))
                }
            }
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
