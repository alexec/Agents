import Foundation

/// Which archived agents to retire, and what each archived row says (051, research R5).
///
/// Pure, like the lease book and the event log: the daemon gathers the facts — the
/// archived agents, their sizes, what holds any of them, the settings and a clock it
/// trusts — and every rule about them is a function of those, tested without a daemon.
public enum RetentionPlan {
    /// Nothing is retired within this long of being archived, by any rule (FR-006).
    public static let floor: TimeInterval = 86_400
    /// A retirement by age is shown on the row once it is this close.
    public static let notice: TimeInterval = 7 * 86_400

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

    public struct Retiring: Hashable, Sendable {
        public var id: UUID
        public var because: RetiredBecause

        public init(id: UUID, because: RetiredBecause) {
            self.id = id
            self.because = because
        }
    }

    public struct Decision: Hashable, Sendable {
        /// In the order they should go.
        public var retire: [Retiring] = []
        /// Only the agents with something to say. One not here says nothing.
        public var notes: [UUID: Retirement] = [:]
        public var overCap: OverCap?
    }

    /// `saneNow` is the time the rules count from: `RetentionClock`'s, not the wall's.
    public static func decide(archived: [Candidate], holds: [UUID: Hold],
                              settings: RetentionSettings, saneNow: Date) -> Decision {
        var decision = Decision()
        guard !settings.isOff else { return decision }

        // An archive time in the future is now: a clock that was ahead when the agent
        // was archived must not make it older than it is.
        func age(_ agent: Candidate) -> TimeInterval { max(0, saneNow.timeIntervalSince(agent.archivedAt)) }
        func pastFloor(_ agent: Candidate) -> Bool { age(agent) >= floor }

        var retired = Set<UUID>()

        // Age.
        if let keep = settings.keepFor.interval {
            for agent in archived.sorted(by: capOrder) where pastFloor(agent) && age(agent) >= keep {
                if let hold = holds[agent.id] {
                    decision.notes[agent.id] = .held(hold)
                } else {
                    decision.retire.append(Retiring(id: agent.id, because: .age))
                    retired.insert(agent.id)
                }
            }
        }

        // The cap, over what age left.
        let remaining = archived.filter { !retired.contains($0.id) }.sorted(by: capOrder)
        var total = remaining.reduce(0) { $0 + $1.sizeOnDisk }
        if let cap = settings.cap.bytes, total > cap {
            var holding: [Hold: Int] = [:]
            for agent in remaining where total > cap {
                if !pastFloor(agent) {
                    holding[.firstDay, default: 0] += 1
                } else if let hold = holds[agent.id] {
                    decision.notes[agent.id] = .held(hold)
                    holding[hold, default: 0] += 1
                } else {
                    decision.retire.append(Retiring(id: agent.id, because: .cap))
                    retired.insert(agent.id)
                    total -= agent.sizeOnDisk
                }
            }
            if total > cap { decision.overCap = OverCap(bytesOver: total - cap, holding: holding) }
        }

        let kept = archived.filter { !retired.contains($0.id) && decision.notes[$0.id] == nil }

        // Soon by age.
        if let keep = settings.keepFor.interval {
            for agent in kept {
                let due = agent.archivedAt.addingTimeInterval(keep)
                if due.timeIntervalSince(saneNow) <= notice { decision.notes[agent.id] = .at(due) }
            }
        }

        // Next under the cap: one agent, and only when one more archiving of the usual
        // size would push the archive over. Far under the cap, it would be a warning
        // about nothing.
        if let cap = settings.cap.bytes, decision.overCap == nil {
            let left = kept.sorted(by: capOrder)
            let sizes = archived.map(\.sizeOnDisk).sorted()
            let usual = sizes.isEmpty ? 0 : sizes[sizes.count / 2]
            if total + usual > cap,
               let next = left.first(where: { pastFloor($0) && decision.notes[$0.id] == nil }) {
                decision.notes[next.id] = .nextUnderCap
            }
        }
        return decision
    }

    /// Oldest archived first, and among those archived together, the one idle longest.
    static func capOrder(_ a: Candidate, _ b: Candidate) -> Bool {
        a.archivedAt != b.archivedAt ? a.archivedAt < b.archivedAt : a.lastActivityAt < b.lastActivityAt
    }
}

/// The time retirement counts from (051, research R5).
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
