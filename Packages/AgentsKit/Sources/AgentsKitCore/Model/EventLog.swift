import Foundation

/// Everything that happened, oldest first (042).
///
/// Pure, like the lease book: the daemon owns one copy, the store writes what changes,
/// and every rule about folding, keeping and finding events is a function of the log
/// and the time, tested without a daemon.
public struct EventLog: Codable, Hashable, Sendable {
    /// Oldest first, by position.
    public private(set) var events: [Event] = []

    public init(events: [Event] = []) {
        self.events = events.sorted { $0.position < $1.position }
    }

    // MARK: Limits (FR-031, FR-032)

    /// Repeats of the same event inside this are one row with a count.
    public static let repeatWindow: TimeInterval = 60
    /// Events older than this are dropped.
    public static let keepFor: TimeInterval = 7 * 24 * 60 * 60
    /// And never more than this many, the oldest going first.
    public static let maximumEvents = 10_000
    /// The most one page asks for.
    public static let pageLimit = 200

    /// The newest position in the log, or zero for an empty one. Waiting from here
    /// means "anything after now".
    public var head: EventPosition { events.last?.position ?? 0 }

    // MARK: Changing it

    public enum Appended: Hashable, Sendable {
        case new(Event)
        /// Folded into the last event, which is returned with its count raised.
        case repeated(Event)

        public var event: Event {
            switch self {
            case .new(let event), .repeated(let event): return event
            }
        }
    }

    /// The draft as a new event at `position`, or folded into the last event when it is
    /// that event again within the window. `position` is not used by a repeat.
    public mutating func append(_ draft: EventDraft, position: EventPosition, now: Date) -> Appended {
        if var last = events.last, Self.isRepeat(draft, of: last, now: now) {
            last.count += 1
            last.lastAt = now
            events[events.count - 1] = last
            return .repeated(last)
        }
        let event = Event(draft, position: position)
        events.append(event)
        return .new(event)
    }

    /// Put a repeat back, as read from the store: a count and a time.
    public mutating func applyRepeat(of position: EventPosition, at: Date) {
        guard let index = index(of: position) else { return }
        events[index].count += 1
        events[index].lastAt = at
    }

    /// Put a whole event in, as read from the store.
    public mutating func insert(_ event: Event) {
        if let index = index(of: event.position) {
            events[index] = event
        } else if event.position > head {
            events.append(event)
        } else {
            events.append(event)
            events.sort { $0.position < $1.position }
        }
    }

    @discardableResult
    public mutating func addConsequence(_ consequence: Consequence, to position: EventPosition) -> Event? {
        guard let index = index(of: position) else { return nil }
        events[index].consequences.append(consequence)
        return events[index]
    }

    /// Drop what is too old, then what is too many. Returns whether anything went.
    @discardableResult
    public mutating func prune(now: Date) -> Bool {
        let before = events.count
        let cutoff = now.addingTimeInterval(-Self.keepFor)
        events.removeAll { $0.latest < cutoff }
        if events.count > Self.maximumEvents {
            events.removeFirst(events.count - Self.maximumEvents)
        }
        return events.count != before
    }

    // MARK: Reading it

    public func event(at position: EventPosition) -> Event? {
        index(of: position).map { events[$0] }
    }

    /// A page, newest first, and whether there is more before it.
    ///
    /// `scopes` and `groups` narrow it; `nil` for either means all. `before` pages back
    /// from a position the reader already has.
    public func query(before: EventPosition? = nil, limit: Int = pageLimit,
                      scopes: Set<EventScope>? = nil, groups: Set<EventGroup>? = nil) -> (events: [Event], hasMore: Bool) {
        let limit = max(1, min(limit, Self.pageLimit))
        var page: [Event] = []
        var hasMore = false
        for event in events.reversed() {
            if let before, event.position >= before { continue }
            if let scopes, !scopes.contains(event.scope) { continue }
            if let groups, !(event.subject.map { groups.contains($0.group) } ?? false) { continue }
            guard page.count < limit else { hasMore = true; break }
            page.append(event)
        }
        return (page, hasMore)
    }

    /// Every event after `position` that any of the patterns match, in the scopes
    /// given, oldest first. What a wait from an earlier point looks at first (R6).
    public func matches(after position: EventPosition, _ patterns: [EventPattern],
                        scopes: Set<EventScope>) -> [Event] {
        events.filter { event in
            event.position > position && scopes.contains(event.scope)
                && patterns.contains { $0.matches(event) }
        }
    }

    // MARK: Inside

    static func isRepeat(_ draft: EventDraft, of last: Event, now: Date) -> Bool {
        last.name == draft.name && last.scope == draft.scope && last.details == draft.details
            && last.publisher == draft.publisher && last.message == draft.message
            && now.timeIntervalSince(last.latest) < repeatWindow
    }

    private func index(of position: EventPosition) -> Int? {
        // Positions only go up, so the log is sorted by them and a binary search finds one.
        var low = 0, high = events.count - 1
        while low <= high {
            let mid = (low + high) / 2
            if events[mid].position == position { return mid }
            if events[mid].position < position { low = mid + 1 } else { high = mid - 1 }
        }
        return nil
    }
}
