import Foundation

/// Which archived agents the age rule deletes (051, #398).
///
/// Pure, like the lease book and the event log: the daemon gathers the facts — the
/// archived agents, what holds any of them, the settings and a clock it trusts — and the
/// rule is a function of those, tested without a daemon.
public enum RetentionPlan {
    /// Nothing is deleted within this long of being archived (FR-006).
    public static let floor: TimeInterval = 86_400

    public struct Candidate: Hashable, Sendable {
        public var id: UUID
        public var archivedAt: Date
        public var lastActivityAt: Date
        public var sizeOnDisk: Int

        public init(id: UUID, archivedAt: Date, lastActivityAt: Date, sizeOnDisk: Int) {
            self.id = id
            self.archivedAt = archivedAt
            self.lastActivityAt = lastActivityAt
            self.sizeOnDisk = sizeOnDisk
        }
    }

    /// The agents to delete, oldest archived first. `saneNow` is the time the rule counts
    /// from: `RetentionClock`'s, not the wall's.
    public static func decide(archived: [Candidate], holds: [UUID: Hold],
                              settings: RetentionSettings, saneNow: Date) -> [UUID] {
        guard let keep = settings.keepFor.interval else { return [] }
        // An archive time in the future is now: a clock that was ahead when the agent
        // was archived must not make it older than it is.
        func age(_ agent: Candidate) -> TimeInterval { max(0, saneNow.timeIntervalSince(agent.archivedAt)) }
        return archived.sorted(by: order)
            .filter { age($0) >= max(floor, keep) && holds[$0.id] == nil }
            .map(\.id)
    }

    /// Oldest archived first, and among those archived together, the one idle longest.
    static func order(_ a: Candidate, _ b: Candidate) -> Bool {
        a.archivedAt != b.archivedAt ? a.archivedAt < b.archivedAt : a.lastActivityAt < b.lastActivityAt
    }
}

/// The time deletion by age counts from (051, research R5).
///
/// The wall clock, unless it jumped forward by more than a day: then only the time that
/// really passed counts, until a day of it has, so a clock set wrong cannot empty the
/// archive at once. Across a restart nothing tells a jump from time the daemon was not
/// running, so a start more than a day after the last check is treated the same way.
///
/// `lastWall` and `lastSane` are written down; the uptime and the distrust are this run's.
public struct RetentionClock: Codable, Hashable, Sendable {
    public static let tolerance: TimeInterval = 86_400

    public private(set) var lastWall: Date?
    public private(set) var lastSane: Date?
    private var lastUptime: TimeInterval?
    /// How much more real time must pass before the wall clock is believed again.
    private var distrust: TimeInterval = 0

    enum CodingKeys: String, CodingKey { case lastWall, lastSane }

    public init() {}

    /// `uptime` is a monotonic reading in seconds, from any origin that holds for the run.
    public mutating func tick(now: Date, uptime: TimeInterval) -> Date {
        let sane: Date
        if let lastWall, let lastSane {
            if let lastUptime {
                let elapsed = max(0, uptime - lastUptime)
                if now.timeIntervalSince(lastWall) - elapsed > Self.tolerance {
                    distrust = Self.tolerance
                    sane = lastSane.addingTimeInterval(elapsed)
                } else if distrust > 0 {
                    distrust -= elapsed
                    if distrust > 0 {
                        sane = lastSane.addingTimeInterval(elapsed)
                    } else {
                        distrust = 0
                        sane = now
                    }
                } else {
                    sane = now
                }
            } else if now.timeIntervalSince(lastWall) > Self.tolerance {
                distrust = Self.tolerance
                sane = lastSane
            } else {
                sane = now
            }
        } else {
            sane = now
        }
        lastWall = now
        lastSane = sane
        lastUptime = uptime
        return sane
    }
}
