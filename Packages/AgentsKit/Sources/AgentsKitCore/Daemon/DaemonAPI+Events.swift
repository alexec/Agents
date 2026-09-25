import Foundation

// Events and waiting (042), kept in a file of its own so the lanes building beside it
// do not collide in DaemonAPI.swift. contracts/daemon-api.md is the reference.

public extension DaemonAPI.Method {
    /// `wait_for_event`, relayed: wait, or read recent events, or list the catalogue.
    static let eventsWait = "events/wait"
    /// `cancel_wait`, relayed.
    static let eventsCancel = "events/cancel"
    /// `publish_event`, relayed.
    static let eventsPublish = "events/publish"
    /// A page of the log and who is waiting, for the Mac's page and the phone's list.
    static let eventsList = "events/list"
    /// The person cancelling an agent's wait from the Mac. The phone cannot: it reads.
    static let eventsCancelWait = "events/cancelWait"
    /// Raise an event by hand. Debug builds on a scratch root only: how the events page
    /// is seen before anything real raises one.
    static let eventsRaise = "events/raise"
}

public extension DaemonAPI.Notification {
    /// A new event, a repeat or consequence added to one, or a change to who is waiting.
    static let eventsChanged = "events/changed"
}

public extension DaemonAPI.Failure {
    /// An event name, filter, scope or publish the app will not take: unknown, outside
    /// the caller's project, outside `custom.`, or over the publish limit. The message
    /// says which, and what would do (042 R16).
    static let eventRefused = -32050
    /// Cancelling a wait when there is none.
    static let noWait = -32051
}

public extension DaemonAPI {
    struct EventWaitRequest: Codable, Sendable, Hashable {
        public var token: String
        /// `wait` (the default), `recent` or `list`.
        public var action: String?
        public var events: [String]?
        public var `where`: [String: String]?
        public var from: EventPosition?
        public var untilMinutes: Int?
        public var limit: Int?

        public init(token: String, action: String? = nil, events: [String]? = nil,
                    where filters: [String: String]? = nil, from: EventPosition? = nil,
                    untilMinutes: Int? = nil, limit: Int? = nil) {
            self.token = token
            self.action = action
            self.events = events
            self.where = filters
            self.from = from
            self.untilMinutes = untilMinutes
            self.limit = limit
        }
    }

    struct EventTokenRequest: Codable, Sendable, Hashable {
        public var token: String
        public init(token: String) { self.token = token }
    }

    struct EventPublishRequest: Codable, Sendable, Hashable {
        public var token: String
        public var name: String
        public var message: String?
        public var details: [String: String]?

        public init(token: String, name: String, message: String? = nil, details: [String: String]? = nil) {
            self.token = token
            self.name = name
            self.message = message
            self.details = details
        }
    }

    struct EventsListRequest: Codable, Sendable, Hashable {
        public var before: EventPosition?
        public var limit: Int
        /// One scope, or all when nil.
        public var scope: EventScope?
        /// Some of the page's capsules, or all when nil.
        public var groups: [EventGroup]?

        public init(before: EventPosition? = nil, limit: Int = EventLog.pageLimit,
                    scope: EventScope? = nil, groups: [EventGroup]? = nil) {
            self.before = before
            self.limit = limit
            self.scope = scope
            self.groups = groups
        }
    }

    struct CancelWaitRequest: Codable, Sendable, Hashable {
        public var agentID: UUID
        public init(agentID: UUID) { self.agentID = agentID }
    }

    /// One agent in the page's Waiting now strip.
    struct WaitingAgent: Codable, Sendable, Hashable, Identifiable {
        public var agentID: UUID
        public var title: String
        public var folder: URL
        public var status: WaitStatus

        public var id: UUID { agentID }

        public init(agentID: UUID, title: String, folder: URL, status: WaitStatus) {
            self.agentID = agentID
            self.title = title
            self.folder = folder
            self.status = status
        }
    }

    struct EventsPage: Codable, Sendable, Hashable {
        /// Newest first.
        public var events: [Event]
        public var waiting: [WaitingAgent]
        public var hasMore: Bool

        public init(events: [Event], waiting: [WaitingAgent], hasMore: Bool) {
            self.events = events
            self.waiting = waiting
            self.hasMore = hasMore
        }
    }

    /// What `events/changed` carries: the event that is new or changed, if one is, and
    /// the whole Waiting now strip, which is small.
    struct EventsChange: Codable, Sendable, Hashable {
        public var event: Event?
        public var waiting: [WaitingAgent]

        public init(event: Event?, waiting: [WaitingAgent]) {
            self.event = event
            self.waiting = waiting
        }
    }

    /// `events/raise`: a draft, and optionally consequences to hang on it, so the page
    /// can be seen whole before anything real produces them.
    struct EventRaiseRequest: Codable, Sendable, Hashable {
        public var draft: EventDraft
        public var consequences: [Consequence]?

        public init(draft: EventDraft, consequences: [Consequence]? = nil) {
            self.draft = draft
            self.consequences = consequences
        }
    }
}
