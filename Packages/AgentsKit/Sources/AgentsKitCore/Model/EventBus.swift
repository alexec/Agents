import Foundation

public extension DaemonAPI {
    /// An event on the bus (#4729, spec 4724-event-bus): its envelope only, no data.
    struct BusEvent: Codable, Sendable, Hashable {
        public var specversion: String
        /// The event's ref (#4728): the subject's ref, `@`, the type, and a key when it can
        /// happen again.
        public var id: String
        public var type: String
        public var provider: String
        public var topic: String
        public var subject: WireRef?
        public var source: String
        /// RFC 3339.
        public var time: String
        /// The machine that raised it, `agents:machine:#<machine>`.
        public var producer: String

        public init(specversion: String = "1.0", id: String, type: String, provider: String, topic: String,
                    subject: WireRef? = nil, source: String? = nil, time: String, producer: String) {
            self.specversion = specversion
            self.id = id
            self.type = type
            self.provider = provider
            self.topic = topic
            self.subject = subject
            self.source = source ?? "\(provider):\(topic)"
            self.time = time
            self.producer = producer
        }

        /// An envelope's RFC 3339 time, with or without its fraction.
        public static func date(_ text: String) -> Date? {
            let fraction = ISO8601DateFormatter()
            fraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return fraction.date(from: text) ?? ISO8601DateFormatter().date(from: text)
        }
    }

    /// `bus/log` (#4732): a page of the person's bus log, newest first, narrowed by the
    /// envelope's provider, type (a name or `noun.*`) and topic.
    struct BusLogQuery: Codable, Sendable, Hashable {
        public var before: String?
        public var limit: Int?
        public var provider: String?
        public var type: String?
        public var topic: String?

        public init(before: String? = nil, limit: Int? = nil, provider: String? = nil, type: String? = nil,
                    topic: String? = nil) {
            self.before = before
            self.limit = limit
            self.provider = provider
            self.type = type
            self.topic = topic
        }
    }

    /// `bus/log`'s answer: envelopes newest first, and where the next page back starts.
    struct BusLogPage: Codable, Sendable, Hashable {
        public var events: [BusEvent]
        public var next: String?
        public var hasMore: Bool

        public init(events: [BusEvent], next: String? = nil, hasMore: Bool) {
            self.events = events
            self.next = next
            self.hasMore = hasMore
        }
    }
}

public extension DaemonAPI.Method {
    /// `BusLogQuery` → `BusLogPage` (#4732): the Events page's list of every machine.
    static let busLog = "bus/log"
}
