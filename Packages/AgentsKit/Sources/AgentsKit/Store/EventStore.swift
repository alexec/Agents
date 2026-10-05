import Foundation
import AgentsKitCore

/// The event log and the event sources' memory, kept where a restarted daemon finds
/// them (042 R13, R14).
///
/// The log is append-only: one line per event, per consequence, per repeat, each a
/// whole JSON object on one line. Writing the whole log on every event would be up to
/// four megabytes a time; appending is one short write. The file is rewritten only when
/// the oldest events are dropped, through a temporary file and a rename, so a daemon
/// killed mid-rewrite leaves the old file whole.
///
/// Each line goes to the file in one `write` on a descriptor opened with `O_APPEND`, so
/// a line is never split by another and always lands at the end. A torn last line — a
/// daemon killed mid-write — is skipped on reading, with one line in the log, and ended
/// with a newline before the next append, so it never swallows the event after it
/// (#177). A file that cannot be read at all is set aside and the log starts empty: losing the record of
/// what happened is the lesser failure, beside a daemon that will not start.
public final class EventStore: @unchecked Sendable {
    private let locations: StoreLocations
    private let lock = NSLock()
    private var handle: FileHandle?
    /// Lines appended since the file was last written whole, and the repeat lines it
    /// held when read: what tells a log of repeats it is due to be compacted (#218).
    private var appendedLines = 0
    /// `events-state.json` as last read or written, so the same state is not written
    /// twice (#218).
    private var savedState: EventState?
    /// How many times `events-state.json` has been written, for the tests.
    private(set) var stateWrites = 0

    public init(locations: StoreLocations) {
        self.locations = locations
    }

    deinit { try? handle?.close() }

    /// One line of the log.
    public enum Line: Codable, Hashable, Sendable {
        case event(Event)
        case consequence(Consequence, position: EventPosition)
        /// The event at this position has now happened `count` times, the last at `at`.
        case repeatOf(EventPosition, at: Date, count: Int)

        private enum Keys: String, CodingKey { case event, consequence, position, `repeat`, at, count }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            if let event = try c.decodeIfPresent(Event.self, forKey: .event) {
                self = .event(event)
            } else if let consequence = try c.decodeIfPresent(Consequence.self, forKey: .consequence) {
                self = .consequence(consequence, position: try c.decode(EventPosition.self, forKey: .position))
            } else {
                self = .repeatOf(try c.decode(EventPosition.self, forKey: .repeat),
                                 at: try c.decode(Date.self, forKey: .at),
                                 count: try c.decode(Int.self, forKey: .count))
            }
        }

        public func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: Keys.self)
            switch self {
            case .event(var event):
                // Consequences travel as their own lines, so that adding one is an
                // append; an event line carries none.
                event.consequences = []
                try c.encode(event, forKey: .event)
            case .consequence(let consequence, let position):
                try c.encode(consequence, forKey: .consequence)
                try c.encode(position, forKey: .position)
            case .repeatOf(let position, let at, let count):
                try c.encode(position, forKey: .repeat)
                try c.encode(at, forKey: .at)
                try c.encode(count, forKey: .count)
            }
        }
    }

    // MARK: The log

    public var linesSinceRewrite: Int { lock.withLock { appendedLines } }

    public func load() -> EventLog {
        lock.lock(); defer { lock.unlock() }
        appendedLines = 0
        // A read error is tried again, then holds the log for the run: the hourly prune's
        // rewrite would otherwise replace it with nothing (#205). Appends still land.
        guard case .read(let data) = StoreFile.read(at: locations.events, meaning: "starting with no events",
                                                    decode: { $0 }) else { return EventLog() }
        var log = EventLog()
        var unreadable = 0
        var torn = false
        var repeats = 0
        let lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        for (index, bytes) in lines.enumerated() {
            guard let line = try? StoreCoding.decoder.decode(Line.self, from: Data(bytes)) else {
                // The last line may be torn; anything else unreadable is counted.
                if index == lines.count - 1 { torn = true } else { unreadable += 1 }
                continue
            }
            switch line {
            case .event(let event): log.insert(event)
            case .consequence(let consequence, let position): log.addConsequence(consequence, to: position)
            case .repeatOf(let position, let at, let count):
                log.applyRepeat(of: position, at: at, count: count)
                repeats += 1
            }
        }
        // Repeat lines read are counted as appended: a file grown long on them is
        // compacted at the next repeat.
        appendedLines = repeats
        if unreadable > 0 && log.events.isEmpty {
            try? handle?.close()
            handle = nil
            StoreFile.setAside(locations.events, meaning: "starting with no events")
            return EventLog()
        }
        if unreadable > 0 {
            // The next prune rewrites without them, so the whole file is kept first.
            let aside = StoreCoding.setAside(locations.events, copy: true)
            DaemonLog.shared.write("events.jsonl: skipped \(unreadable) unreadable line(s)"
                + (aside.map { "; the whole file is kept as \($0.lastPathComponent)" } ?? ""))
            if let aside { SetAsideNotes.shared.add(locations.events, aside: aside, partly: true) }
        }
        if torn {
            DaemonLog.shared.write("events.jsonl: skipped a torn last line (\(lines.last?.count ?? 0) bytes), from a daemon stopped mid-write")
        }
        return log
    }

    /// The refusal comes back for the daemon to tell (#212); nothing waits on it.
    @discardableResult
    public func append(_ line: Line) -> (any Error)? {
        lock.lock(); defer { lock.unlock() }
        guard var data = try? StoreCoding.encoder.encode(line) else { return nil }
        data.append(UInt8(ascii: "\n"))
        do {
            // One write: with O_APPEND the line lands at the end whole, or not at all.
            try openHandle().write(contentsOf: data)
            appendedLines += 1
        } catch {
            try? self.handle?.close()
            self.handle = nil
            DaemonLog.shared.write("events.jsonl: could not append: \(error.localizedDescription)")
            return error
        }
        return nil
    }

    /// Write the whole log afresh, as the lines it would have been appended as.
    @discardableResult
    public func rewrite(_ log: EventLog) -> (any Error)? {
        lock.lock(); defer { lock.unlock() }
        var data = Data()
        for event in log.events {
            let lines = [Line.event(event)] + event.consequences.map { Line.consequence($0, position: event.position) }
                + (event.count > 1 ? [Line.repeatOf(event.position, at: event.latest, count: event.count)] : [])
            for line in lines {
                guard let encoded = try? StoreCoding.encoder.encode(line) else { continue }
                data.append(encoded)
                data.append(UInt8(ascii: "\n"))
            }
        }
        do {
            try FileManager.default.createDirectory(at: locations.root, withIntermediateDirectories: true)
            try? handle?.close()
            handle = nil
            try StoreFile.write(data, to: locations.events)
            appendedLines = 0
        } catch {
            DaemonLog.shared.write("events.jsonl: could not rewrite: \(error.localizedDescription)")
            return error
        }
        return nil
    }

    /// The log, opened for appending. A file that does not end with a newline ends with
    /// a torn line, and is given one first, so the next line starts on a line of its own.
    private func openHandle() throws -> FileHandle {
        if let handle { return handle }
        try FileManager.default.createDirectory(at: locations.root, withIntermediateDirectories: true)
        let fd = open(locations.events.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw StoreCoding.writeError(errno, at: locations.events) }
        let opened = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        if Self.endsTorn(locations.events) {
            try opened.write(contentsOf: Data([UInt8(ascii: "\n")]))
        }
        handle = opened
        return opened
    }

    /// Whether the file has bytes and its last is not a newline.
    static func endsTorn(_ url: URL) -> Bool {
        guard let reading = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? reading.close() }
        guard let end = try? reading.seekToEnd(), end > 0 else { return false }
        try? reading.seek(toOffset: end - 1)
        return (try? reading.read(upToCount: 1)) != Data([UInt8(ascii: "\n")])
    }

    // MARK: The sources' memory

    public func loadState() -> EventState {
        let state = StoreFile.load(EventState.self, at: locations.eventState, empty: EventState(), meaning: "starting afresh")
        lock.withLock { savedState = state }
        return state
    }

    /// Written only when it differs from what was last read or written.
    @discardableResult
    public func saveState(_ state: EventState) -> (any Error)? {
        lock.lock(); defer { lock.unlock() }
        guard state != savedState else { return nil }
        do {
            try FileManager.default.createDirectory(at: locations.root, withIntermediateDirectories: true)
            try StoreFile.write(StoreCoding.encoder.encode(state), to: locations.eventState)
            savedState = state
            stateWrites += 1
        } catch {
            DaemonLog.shared.write("events-state.json: could not save: \(error.localizedDescription)")
            return error
        }
        return nil
    }
}

/// What the event sources remember between runs, so a restart raises what changed
/// while it was down (once, when noticed) and nothing it has already said (042 R8, R9).
public struct EventState: Codable, Hashable, Sendable {
    /// The position the next event gets. Written before the event is appended, so a
    /// daemon killed between the two leaves a gap, never a position used twice (R6).
    public var nextPosition: EventPosition = 1
    /// Project folder path → branch → commit, as last seen.
    public var branchTips: [String: [String: String]] = [:]
    /// Agent id → when it published, over the last hour.
    public var publishes: [String: [Date]] = [:]
    /// Day ("2026-09-25") → the limits already said to be reached that day.
    public var costCrossings: [String: [String]] = [:]
    /// Volume mount → how it stood at the last look (#195), so a crossing is raised
    /// once and a restart does not raise it again.
    public var diskLevels: [String: String]?

    public init() {}
}

