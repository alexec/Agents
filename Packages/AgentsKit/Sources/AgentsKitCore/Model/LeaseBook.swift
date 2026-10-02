import Foundation

/// Every lease on the Mac and everyone waiting, and every rule about them (036).
///
/// A value, not an actor. Each change is a mutating call that takes the time and says
/// what happened, and nothing here awaits: that is what lets the daemon's actor be the
/// whole of the lock, and what lets "never more holders than allowed" (SC-001, and
/// #116's counted ones) be tested as a property of one function rather than by
/// racing a daemon.
///
/// The daemon applies what comes back — saying it in transcripts, answering the calls
/// that were waiting, starting the agents that were not — and nothing in here knows
/// any of that exists.
public struct LeaseBook: Codable, Hashable, Sendable {
    public struct Entry: Codable, Hashable, Sendable {
        public var kind: ResourceKind
        public var displayName: String
        /// Everyone holding it, in the order they got it. At most `rules.holders`, unless
        /// the person lowered the count while more held it: those keep their leases, and
        /// nobody new gets one until the count is under again (#116).
        public var leases: [Lease]
        /// In asking order. Empty whenever there is room: a resource with a free place
        /// and a line would be one somebody forgot to hand on.
        public var line: [Waiter]
        /// How many may hold it and for how long. The standard ones unless the person
        /// declared it otherwise.
        public var rules: LeaseRules

        public init(kind: ResourceKind, displayName: String, leases: [Lease] = [], line: [Waiter] = [],
                    rules: LeaseRules = .standard) {
            self.kind = kind
            self.displayName = displayName
            self.leases = leases
            self.line = line
            self.rules = rules
        }

        public init(kind: ResourceKind, displayName: String, lease: Lease?, line: [Waiter] = []) {
            self.init(kind: kind, displayName: displayName, leases: lease.map { [$0] } ?? [], line: line)
        }

        /// The first holder: the one holder of a resource only one may hold.
        public var lease: Lease? { leases.first }

        /// Every place taken.
        public var isFull: Bool { leases.count >= rules.holders }

        /// The lease that ends first: what someone in line is waiting on.
        public var nextToEnd: Lease? { leases.min { $0.expiresAt < $1.expiresAt } }

        public func lease(of agent: UUID) -> Lease? { leases.first { $0.holder == agent } }

        private enum CodingKeys: String, CodingKey { case kind, displayName, leases, lease, line, rules }

        /// A book written before #116 has one `lease` and no rules.
        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            kind = try container.decode(ResourceKind.self, forKey: .kind)
            displayName = try container.decode(String.self, forKey: .displayName)
            if let leases = try container.decodeIfPresent([Lease].self, forKey: .leases) {
                self.leases = leases
            } else {
                leases = try container.decodeIfPresent(Lease.self, forKey: .lease).map { [$0] } ?? []
            }
            line = try container.decodeIfPresent([Waiter].self, forKey: .line) ?? []
            rules = try container.decodeIfPresent(LeaseRules.self, forKey: .rules) ?? .standard
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(kind, forKey: .kind)
            try container.encode(displayName, forKey: .displayName)
            try container.encode(leases, forKey: .leases)
            try container.encode(line, forKey: .line)
            try container.encode(rules, forKey: .rules)
        }
    }

    public private(set) var entries: [ResourceName: Entry]
    /// What each agent is to be told at its next lease call, by agent id.
    public private(set) var notices: [String: [LeaseNotice]]

    public init() {
        entries = [:]
        notices = [:]
    }

    /// The names, in one order, so a pass over them says things in the same order
    /// every time.
    public var names: [ResourceName] { entries.keys.sorted() }

    public var isEmpty: Bool { entries.isEmpty }

    /// Whether anyone is waiting for anything. What keeps the daemon up: a waiter can
    /// only be let through by a daemon that is running (research R10).
    public var hasWaiters: Bool { entries.values.contains { !$0.line.isEmpty } }

    /// Whether anyone holds anything.
    public var anythingHeld: Bool { entries.values.contains { !$0.leases.isEmpty } }

    // MARK: Asking

    /// An agent asking for a resource.
    ///
    /// A place free: granted. Its own: extended, never a second lease and never a wait
    /// on itself (US1-AS4). Every place taken: in line at the back, or refused with
    /// `wait` false. Already in line: its place, unchanged, with the new call's id.
    ///
    /// `rules` are used for a resource the book does not have yet; one it has keeps
    /// its own, which `setRules` changes.
    public mutating func request(_ name: ResourceName, kind: ResourceKind, displayName: String,
                                 rules: LeaseRules = .standard,
                                 by agent: UUID, minutes: Int?, wait: Bool, waitID: UUID?,
                                 now: Date) -> [LeaseEvent] {
        var entry = entries[name] ?? Entry(kind: kind, displayName: displayName, rules: rules)
        defer { store(entry, at: name) }
        let (length, capped) = entry.rules.length(minutes)

        if let index = entry.leases.firstIndex(where: { $0.holder == agent }) {
            var lease = entry.leases[index]
            // Forward only. An extension asking for less than is left is not a way to
            // shorten a lease, and must not be one by accident.
            let wanted = max(lease.expiresAt, now.addingTimeInterval(length))
            let ceiling = now.addingTimeInterval(TimeInterval(entry.rules.ceiling * 60))
            lease.expiresAt = min(wanted, ceiling)
            lease.warned = false
            entry.leases[index] = lease
            return [.extended(lease, capped: capped || wanted > ceiling)]
        }
        if !entry.isFull && entry.line.isEmpty {
            let lease = Lease(resource: name, displayName: entry.displayName, holder: agent,
                              grantedAt: now, expiresAt: now.addingTimeInterval(length))
            entry.leases.append(lease)
            return [.granted(lease, waiter: nil, capped: capped)]
        }
        let next = entry.nextToEnd
        let (holder, until) = (next?.holder ?? agent, next?.expiresAt ?? now)
        if let index = entry.line.firstIndex(where: { $0.agentID == agent }) {
            if wait { entry.line[index].waitID = waitID }
            return [.stillWaiting(place: index + 1, holder: holder, until: until)]
        }
        guard wait else {
            return [.refused(holder: holder, until: until)]
        }
        entry.line.append(Waiter(agentID: agent, askedAt: now, minutes: minutes, waitID: waitID))
        return [.queued(place: entry.line.count, holder: holder, until: until)]
    }

    /// The person changing how many may hold a resource, or how long for (#116). More
    /// places let the line in at once; fewer take nothing from those holding it.
    public mutating func setRules(_ rules: LeaseRules, for name: ResourceName, now: Date) -> [LeaseEvent] {
        guard var entry = entries[name], entry.rules != rules else { return [] }
        entry.rules = rules
        let events = handOn(&entry, name: name, now: now)
        store(entry, at: name)
        return events
    }

    // MARK: Letting go

    /// A holder giving its lease back, or a waiter leaving the line.
    public mutating func release(_ name: ResourceName, by agent: UUID, now: Date) -> [LeaseEvent] {
        guard var entry = entries[name] else { return [.nothingHeld] }
        if let index = entry.leases.firstIndex(where: { $0.holder == agent }) {
            let lease = entry.leases.remove(at: index)
            var events: [LeaseEvent] = [.released(lease, .released)]
            events += handOn(&entry, name: name, now: now)
            store(entry, at: name)
            return events
        }
        if let index = entry.line.firstIndex(where: { $0.agentID == agent }) {
            entry.line.remove(at: index)
            store(entry, at: name)
            return [.leftLine(name, displayName: entry.displayName, agent: agent)]
        }
        return [.nothingHeld]
    }

    /// The person ending a lease: one holder's, or with no holder named, every one. The
    /// holder is told at its next lease call, never interrupted (US4-AS2). Nothing when
    /// nobody (or not that agent) holds it.
    public mutating func end(_ name: ResourceName, holder: UUID? = nil, now: Date) -> [LeaseEvent] {
        guard var entry = entries[name] else { return [] }
        let ending = entry.leases.filter { holder == nil || $0.holder == holder }
        guard !ending.isEmpty else { return [] }
        entry.leases.removeAll { holder == nil || $0.holder == holder }
        var events: [LeaseEvent] = []
        for lease in ending {
            leave(LeaseNotice(resource: name, displayName: lease.displayName, kind: .endedByPerson, at: now),
                  for: lease.holder)
            events.append(.released(lease, .endedByPerson))
        }
        events += handOn(&entry, name: name, now: now)
        store(entry, at: name)
        return events
    }

    /// The person taking one agent out of one line.
    public mutating func removeFromLine(_ name: ResourceName, agent: UUID) -> [LeaseEvent] {
        guard var entry = entries[name],
              let index = entry.line.firstIndex(where: { $0.agentID == agent }) else { return [] }
        entry.line.remove(at: index)
        store(entry, at: name)
        return [.leftLine(name, displayName: entry.displayName, agent: agent)]
    }

    /// An agent stopped or archived: out of every line first, then every lease it
    /// holds given back and handed on — in that order, so nothing it held is handed
    /// straight back to it.
    public mutating func drop(_ agent: UUID, because ending: LeaseEnding, now: Date) -> [LeaseEvent] {
        var events: [LeaseEvent] = []
        for name in names {
            guard var entry = entries[name] else { continue }
            if let index = entry.line.firstIndex(where: { $0.agentID == agent }) {
                entry.line.remove(at: index)
                events.append(.leftLine(name, displayName: entry.displayName, agent: agent))
            }
            store(entry, at: name)
        }
        for name in names {
            guard var entry = entries[name], let index = entry.leases.firstIndex(where: { $0.holder == agent })
            else { continue }
            let lease = entry.leases.remove(at: index)
            events.append(.released(lease, ending))
            events += handOn(&entry, name: name, now: now)
            store(entry, at: name)
        }
        notices[agent.uuidString] = nil
        return events
    }

    /// A lease that reached an agent which could not be started to use it (research
    /// R4). Given up for it, and handed on.
    public mutating func giveUp(_ name: ResourceName, heldBy agent: UUID, now: Date) -> [LeaseEvent] {
        guard var entry = entries[name], let index = entry.leases.firstIndex(where: { $0.holder == agent })
        else { return [] }
        let lease = entry.leases.remove(at: index)
        var events: [LeaseEvent] = [.released(lease, .couldNotStart)]
        events += handOn(&entry, name: name, now: now)
        store(entry, at: name)
        return events
    }

    // MARK: Waiting calls

    /// A call that waited as long as a call may. Its place is kept; the agent will be
    /// started when its turn comes instead.
    public mutating func waitTimedOut(_ waitID: UUID) -> [LeaseEvent] {
        for name in names {
            guard var entry = entries[name],
                  let index = entry.line.firstIndex(where: { $0.waitID == waitID }) else { continue }
            entry.line[index].waitID = nil
            store(entry, at: name)
            guard let next = entry.nextToEnd else { return [] }
            return [.stillWaiting(place: index + 1, holder: next.holder, until: next.expiresAt)]
        }
        return []
    }

    /// No call survives a restart. Every waiter will be started instead.
    public mutating func closeAllWaits() {
        for name in names {
            guard var entry = entries[name] else { continue }
            for index in entry.line.indices { entry.line[index].waitID = nil }
            store(entry, at: name)
        }
    }

    // MARK: Time

    /// Whatever the time has done: leases past their expiry released and handed on,
    /// and holders inside the warning window warned once.
    public mutating func lapse(now: Date) -> [LeaseEvent] {
        var events: [LeaseEvent] = []
        for name in names {
            guard var entry = entries[name], !entry.leases.isEmpty else { continue }
            var kept: [Lease] = []
            for var lease in entry.leases {
                if lease.expiresAt <= now {
                    leave(LeaseNotice(resource: name, displayName: lease.displayName, kind: .expired, at: now),
                          for: lease.holder)
                    events.append(.released(lease, .expired))
                    continue
                }
                if !lease.warned, lease.isEndingSoon(at: now) {
                    lease.warned = true
                    leave(LeaseNotice(resource: name, displayName: lease.displayName,
                                      kind: .endingSoon(expiresAt: lease.expiresAt), at: now),
                          for: lease.holder)
                    events.append(.warned(lease))
                }
                kept.append(lease)
            }
            entry.leases = kept
            events += handOn(&entry, name: name, now: now)
            store(entry, at: name)
        }
        return events
    }

    /// When `lapse` next has something to do: the earliest expiry or unwarned warning
    /// time. Nil when nothing is held.
    public var nextDeadline: Date? {
        entries.values.flatMap(\.leases).flatMap { lease -> [Date] in
            lease.warned ? [lease.expiresAt]
                         : [lease.expiresAt, lease.expiresAt.addingTimeInterval(-LeaseLimits.warning)]
        }.min()
    }

    // MARK: Reading

    /// What an agent has been left to be told, given to it once.
    public mutating func takeNotices(for agent: UUID) -> [LeaseNotice] {
        notices.removeValue(forKey: agent.uuidString) ?? []
    }

    public func entry(_ name: ResourceName) -> Entry? { entries[name] }

    /// The leases an agent holds, by name.
    public func held(by agent: UUID) -> [Lease] {
        names.compactMap { entries[$0]?.lease(of: agent) }
    }

    /// The lines an agent is in, with its place in each.
    public func waits(of agent: UUID) -> [(name: ResourceName, entry: Entry, place: Int)] {
        names.compactMap { name in
            guard let entry = entries[name],
                  let index = entry.line.firstIndex(where: { $0.agentID == agent }) else { return nil }
            return (name, entry, index + 1)
        }
    }

    // MARK: Inside

    /// The length asked for under the standard rules, in seconds, and whether it had
    /// to be cut to the longest allowed.
    static func length(_ minutes: Int?) -> (TimeInterval, capped: Bool) {
        LeaseRules.standard.length(minutes)
    }

    /// The next in line, while there is a place, gets one — for what it asked, from now.
    private func handOn(_ entry: inout Entry, name: ResourceName, now: Date) -> [LeaseEvent] {
        var events: [LeaseEvent] = []
        while !entry.isFull, !entry.line.isEmpty {
            let next = entry.line.removeFirst()
            let (length, capped) = entry.rules.length(next.minutes)
            let lease = Lease(resource: name, displayName: entry.displayName, holder: next.agentID,
                              grantedAt: now, expiresAt: now.addingTimeInterval(length))
            entry.leases.append(lease)
            events.append(.granted(lease, waiter: next, capped: capped))
        }
        return events
    }

    /// An entry with nobody holding it and nobody waiting is not kept: the page draws
    /// found and declared resources from their own lists, and a named one ends when
    /// nobody wants it (US6-AS2).
    private mutating func store(_ entry: Entry, at name: ResourceName) {
        entries[name] = entry.leases.isEmpty && entry.line.isEmpty ? nil : entry
    }

    private mutating func leave(_ notice: LeaseNotice, for agent: UUID) {
        notices[agent.uuidString, default: []].append(notice)
    }
}

/// What a change to the book did. The daemon turns each into words, an answer to a
/// waiting call, or a start. Where a line is said, `holder` and `until` are the lease
/// that ends first: the place the waiter is waiting on.
public enum LeaseEvent: Hashable, Sendable {
    /// `waiter` is set when it came from the line; its `waitID` says whether that call
    /// is still open to be answered, or the agent has to be started.
    case granted(Lease, waiter: Waiter?, capped: Bool)
    case extended(Lease, capped: Bool)
    case queued(place: Int, holder: UUID, until: Date)
    case refused(holder: UUID, until: Date)
    case stillWaiting(place: Int, holder: UUID, until: Date)
    case released(Lease, LeaseEnding)
    case leftLine(ResourceName, displayName: String, agent: UUID)
    case nothingHeld
    case warned(Lease)
}
