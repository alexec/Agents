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
/// A torn last line — a daemon killed mid-append — is dropped on reading. A file that
/// cannot be read at all is set aside and the log starts empty: losing the record of
/// what happened is the lesser failure, beside a daemon that will not start.
public final class EventStore: @unchecked Sendable {
    private let locations: StoreLocations
    private let lock = NSLock()
    private var handle: FileHandle?

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

    public func load() -> EventLog {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: locations.events) else { return EventLog() }
        var log = EventLog()
        var unreadable = 0
        let lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        for (index, bytes) in lines.enumerated() {
            guard let line = try? StoreCoding.decoder.decode(Line.self, from: Data(bytes)) else {
                // The last line may be torn; anything else unreadable is counted.
                if index != lines.count - 1 { unreadable += 1 }
                continue
            }
            switch line {
            case .event(let event): log.insert(event)
            case .consequence(let consequence, let position): log.addConsequence(consequence, to: position)
            case .repeatOf(let position, let at, let count): log.applyRepeat(of: position, at: at, count: count)
            }
        }
        if unreadable > 0 && log.events.isEmpty {
            try? handle?.close()
            handle = nil
            StoreCoding.setAside(locations.events)
            DaemonLog.shared.write("events.jsonl could not be read; set aside, starting with no events")
            return EventLog()
        }
        if unreadable > 0 {
            DaemonLog.shared.write("events.jsonl: skipped \(unreadable) unreadable line(s)")
        }
        return log
    }

    public func append(_ line: Line) {
        lock.lock(); defer { lock.unlock() }
        guard var data = try? StoreCoding.encoder.encode(line) else { return }
        data.append(UInt8(ascii: "\n"))
        do {
            let handle = try openHandle()
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            try? self.handle?.close()
            self.handle = nil
            DaemonLog.shared.write("events.jsonl: could not append: \(error.localizedDescription)")
        }
    }

    /// Write the whole log afresh, as the lines it would have been appended as.
    public func rewrite(_ log: EventLog) {
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
            try data.write(to: locations.events, options: .atomic)
        } catch {
            DaemonLog.shared.write("events.jsonl: could not rewrite: \(error.localizedDescription)")
        }
    }

    private func openHandle() throws -> FileHandle {
        if let handle { return handle }
        try FileManager.default.createDirectory(at: locations.root, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: locations.events.path) {
            FileManager.default.createFile(atPath: locations.events.path, contents: nil)
        }
        let opened = try FileHandle(forWritingTo: locations.events)
        handle = opened
        return opened
    }

    // MARK: The sources' memory

    public func loadState() -> EventState {
        guard let data = try? Data(contentsOf: locations.eventState) else { return EventState() }
        guard let state = try? StoreCoding.decoder.decode(EventState.self, from: data) else {
            StoreCoding.setAside(locations.eventState)
            DaemonLog.shared.write("events-state.json could not be read; set aside, starting afresh")
            return EventState()
        }
        return state
    }

    public func saveState(_ state: EventState) {
        do {
            try FileManager.default.createDirectory(at: locations.root, withIntermediateDirectories: true)
            try StoreCoding.encoder.encode(state).write(to: locations.eventState, options: .atomic)
        } catch {
            DaemonLog.shared.write("events-state.json: could not save: \(error.localizedDescription)")
        }
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
    /// Project folder path → the viewer's open pull requests, as last seen.
    public var pullRequestsSeen: [String: [SeenPullRequest]] = [:]
    /// Agent id → when it published, over the last hour.
    public var publishes: [String: [Date]] = [:]
    /// Day ("2026-09-25") → the limits already said to be reached that day.
    public var costCrossings: [String: [String]] = [:]

    public init() {}
}

/// A pull request as the last refresh saw it: enough to tell what changed.
public struct SeenPullRequest: Codable, Hashable, Sendable {
    public var number: Int
    public var title: String
    public var checks: String
    public var review: String
    public var conflicts: String
    public var lastCommentAt: Date?

    public init(number: Int, title: String, checks: String, review: String, conflicts: String,
                lastCommentAt: Date?) {
        self.number = number
        self.title = title
        self.checks = checks
        self.review = review
        self.conflicts = conflicts
        self.lastCommentAt = lastCommentAt
    }
}
