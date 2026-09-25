import Foundation

/// Every lease on the Mac and everyone waiting, and every rule about them (036).
///
/// A value, not an actor. Each change is a mutating call that takes the time and says
/// what happened, and nothing here awaits: that is what lets the daemon's actor be the
/// whole of the lock, and what lets "never two holders" (SC-001) be tested as a
/// property of one function rather than by racing a daemon.
///
/// The daemon applies what comes back — saying it in transcripts, answering the calls
/// that were waiting, starting the agents that were not — and nothing in here knows
/// any of that exists.
public struct LeaseBook: Codable, Hashable, Sendable {
    public struct Entry: Codable, Hashable, Sendable {
        public var kind: ResourceKind
        public var displayName: String
        public var lease: Lease?
        /// In asking order. Empty whenever `lease` is nil: a free resource with a line
        /// would be one somebody forgot to hand on.
        public var line: [Waiter]

        public init(kind: ResourceKind, displayName: String, lease: Lease? = nil, line: [Waiter] = []) {
            self.kind = kind
            self.displayName = displayName
            self.lease = lease
            self.line = line
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

    // MARK: Asking

    /// An agent asking for a resource.
    ///
    /// Free: granted. Its own: extended, never a second lease and never a wait on
    /// itself (US1-AS4). Someone else's: in line at the back, or refused with `wait`
    /// false. Already in line: its place, unchanged, with the new call's id.
    public mutating func request(_ name: ResourceName, kind: ResourceKind, displayName: String,
                                 by agent: UUID, minutes: Int?, wait: Bool, waitID: UUID?,
                                 now: Date) -> [LeaseEvent] {
        var entry = entries[name] ?? Entry(kind: kind, displayName: displayName)
        defer { store(entry, at: name) }
        let (length, capped) = Self.length(minutes)

        guard var lease = entry.lease else {
            let lease = Lease(resource: name, displayName: entry.displayName, holder: agent,
                              grantedAt: now, expiresAt: now.addingTimeInterval(length))
            entry.lease = lease
            return [.granted(lease, waiter: nil, capped: capped)]
        }
        if lease.holder == agent {
            // Forward only. An extension asking for less than is left is not a way to
            // shorten a lease, and must not be one by accident.
            let wanted = max(lease.expiresAt, now.addingTimeInterval(length))
            let ceiling = now.addingTimeInterval(Self.maximum)
            lease.expiresAt = min(wanted, ceiling)
            lease.warned = false
            entry.lease = lease
            return [.extended(lease, capped: capped || wanted > ceiling)]
        }
        if let index = entry.line.firstIndex(where: { $0.agentID == agent }) {
            if wait { entry.line[index].waitID = waitID }
            return [.stillWaiting(place: index + 1, holder: lease.holder, until: lease.expiresAt)]
        }
        guard wait else {
            return [.refused(holder: lease.holder, until: lease.expiresAt)]
        }
        entry.line.append(Waiter(agentID: agent, askedAt: now, minutes: minutes, waitID: waitID))
        return [.queued(place: entry.line.count, holder: lease.holder, until: lease.expiresAt)]
    }

    // MARK: Letting go

    /// The holder giving a lease back, or a waiter leaving the line.
    public mutating func release(_ name: ResourceName, by agent: UUID, now: Date) -> [LeaseEvent] {
        guard var entry = entries[name] else { return [.nothingHeld] }
        if let lease = entry.lease, lease.holder == agent {
            entry.lease = nil
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

    /// The person ending whoever holds it. The holder is told at its next lease call,
    /// never interrupted (US4-AS2). Nothing when nobody holds it.
    public mutating func end(_ name: ResourceName, now: Date) -> [LeaseEvent] {
        guard var entry = entries[name], let lease = entry.lease else { return [] }
        entry.lease = nil
        leave(LeaseNotice(resource: name, displayName: lease.displayName, kind: .endedByPerson, at: now),
              for: lease.holder)
        var events: [LeaseEvent] = [.released(lease, .endedByPerson)]
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
            guard var entry = entries[name], let lease = entry.lease, lease.holder == agent else { continue }
            entry.lease = nil
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
        guard var entry = entries[name], let lease = entry.lease, lease.holder == agent else { return [] }
        entry.lease = nil
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
            guard let lease = entry.lease else { return [] }
            return [.stillWaiting(place: index + 1, holder: lease.holder, until: lease.expiresAt)]
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
            guard var entry = entries[name], var lease = entry.lease else { continue }
            if lease.expiresAt <= now {
                entry.lease = nil
                leave(LeaseNotice(resource: name, displayName: lease.displayName, kind: .expired, at: now),
                      for: lease.holder)
                events.append(.released(lease, .expired))
                events += handOn(&entry, name: name, now: now)
            } else if !lease.warned, lease.isEndingSoon(at: now) {
                lease.warned = true
                entry.lease = lease
                leave(LeaseNotice(resource: name, displayName: lease.displayName,
                                  kind: .endingSoon(expiresAt: lease.expiresAt), at: now),
                      for: lease.holder)
                events.append(.warned(lease))
            }
            store(entry, at: name)
        }
        return events
    }

    /// When `lapse` next has something to do: the earliest expiry or unwarned warning
    /// time. Nil when nothing is held.
    public var nextDeadline: Date? {
        entries.values.compactMap(\.lease).flatMap { lease -> [Date] in
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
        names.compactMap { entries[$0]?.lease }.filter { $0.holder == agent }
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

    private static let maximum = TimeInterval(LeaseLimits.maximumMinutes * 60)

    /// The length asked for, in seconds, and whether it had to be cut to the longest
    /// allowed. Nothing shorter than a minute.
    static func length(_ minutes: Int?) -> (TimeInterval, capped: Bool) {
        let asked = max(1, minutes ?? LeaseLimits.defaultMinutes)
        let given = min(asked, LeaseLimits.maximumMinutes)
        return (TimeInterval(given * 60), asked > given)
    }

    /// The next in line, if there is one, gets it — for what it asked, from now.
    private func handOn(_ entry: inout Entry, name: ResourceName, now: Date) -> [LeaseEvent] {
        guard entry.lease == nil, !entry.line.isEmpty else { return [] }
        let next = entry.line.removeFirst()
        let (length, capped) = Self.length(next.minutes)
        let lease = Lease(resource: name, displayName: entry.displayName, holder: next.agentID,
                          grantedAt: now, expiresAt: now.addingTimeInterval(length))
        entry.lease = lease
        return [.granted(lease, waiter: next, capped: capped)]
    }

    /// An entry with nobody holding it and nobody waiting is not kept: the page draws
    /// found resources from the catalog, and a named one ends when nobody wants it
    /// (US6-AS2).
    private mutating func store(_ entry: Entry, at name: ResourceName) {
        entries[name] = entry.lease == nil && entry.line.isEmpty ? nil : entry
    }

    private mutating func leave(_ notice: LeaseNotice, for agent: UUID) {
        notices[agent.uuidString, default: []].append(notice)
    }
}

/// What a change to the book did. The daemon turns each into words, an answer to a
/// waiting call, or a start.
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
