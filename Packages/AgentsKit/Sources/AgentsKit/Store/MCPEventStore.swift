import Foundation
import AgentsKitCore

/// Where each subscription to a server's events has got to (#383), as `mcp-events.json`.
///
/// The daemon is the only writer. Written whole and synced, because the record is half of
/// exactly-once: ids written into `delivering` before an event is raised, and the event
/// log as the commit point (research R4). Never a payload, a URL or a secret: ids, times
/// and the server's opaque cursor.
public struct MCPSubscriptionRecord: Codable, Hashable, Sendable {
    public struct Seen: Codable, Hashable, Sendable {
        public var id: String
        public var at: Date

        public init(id: String, at: Date) {
            self.id = id
            self.at = at
        }
    }

    /// Ids are kept for a week, and at most this many.
    public static let seenLimit = 2000
    public static let seenFor: TimeInterval = 7 * 24 * 60 * 60
    /// A record no workflow has named for this long is dropped (a changed filter, a
    /// deleted workflow).
    public static let unnamedFor: TimeInterval = 24 * 60 * 60
    /// How long missed events are said, unless cleared first.
    public static let missedFor: TimeInterval = 7 * 24 * 60 * 60

    /// The last cursor the server gave; `nil` before the first poll.
    public var cursor: String?
    /// The one before, to fetch again what was still being delivered.
    public var previousCursor: String?
    public var seen: [Seen]
    /// Ids written ahead of `raise`. Empty when the record is at rest.
    public var delivering: [String]
    public var lastPolledAt: Date?
    public var lastEventAt: Date?
    public var missedSince: Date?
    public var failure: MCPTriggerFailure?
    /// When to ask next, so a restart keeps the pace.
    public var nextPollAt: Date?
    /// When some workflow last named it.
    public var lastNamedAt: Date

    public init(cursor: String? = nil, previousCursor: String? = nil, seen: [Seen] = [], delivering: [String] = [],
                lastPolledAt: Date? = nil, lastEventAt: Date? = nil, missedSince: Date? = nil,
                failure: MCPTriggerFailure? = nil, nextPollAt: Date? = nil, lastNamedAt: Date) {
        self.cursor = cursor
        self.previousCursor = previousCursor
        self.seen = seen
        self.delivering = delivering
        self.lastPolledAt = lastPolledAt
        self.lastEventAt = lastEventAt
        self.missedSince = missedSince
        self.failure = failure
        self.nextPollAt = nextPollAt
        self.lastNamedAt = lastNamedAt
    }

    public func hasSeen(_ id: String) -> Bool { seen.contains { $0.id == id } }

    /// Note ids as seen, then keep a week of them, and at most `seenLimit`.
    public mutating func see(_ ids: [String], at now: Date) {
        for id in ids where !hasSeen(id) { seen.append(Seen(id: id, at: now)) }
        trimSeen(now: now)
    }

    public mutating func trimSeen(now: Date) {
        seen.removeAll { now.timeIntervalSince($0.at) > Self.seenFor }
        if seen.count > Self.seenLimit { seen.removeFirst(seen.count - Self.seenLimit) }
    }
}

/// Every record, keyed `"<project path>|<subscription key>"`.
public struct MCPEventRecords: Codable, Hashable, Sendable {
    public var subscriptions: [String: MCPSubscriptionRecord]

    public init(subscriptions: [String: MCPSubscriptionRecord] = [:]) {
        self.subscriptions = subscriptions
    }

    public static func key(project: URL, subscription: String) -> String {
        Project.standardize(project).path + "|" + subscription
    }

    /// Stamp the keys some workflow names now, and drop those none has named for a day.
    /// Answers whether anything was dropped.
    @discardableResult
    public mutating func prune(keeping named: Set<String>, now: Date) -> Bool {
        for key in named { subscriptions[key]?.lastNamedAt = now }
        let before = subscriptions.count
        subscriptions = subscriptions.filter { key, record in
            named.contains(key) || now.timeIntervalSince(record.lastNamedAt) <= MCPSubscriptionRecord.unnamedFor
        }
        return subscriptions.count != before
    }
}

public struct MCPEventStore: Sendable {
    public let url: URL

    public init(root: URL) {
        url = root.appending(path: "mcp-events.json")
    }

    public func load() -> MCPEventRecords {
        StoreFile.load(MCPEventRecords.self, at: url, empty: MCPEventRecords(),
                       meaning: "every subscription to a server's events starts again from now")
    }

    public func save(_ records: MCPEventRecords) throws {
        try StoreFile.write(StoreCoding.encoder.encode(records), to: url)
    }
}
