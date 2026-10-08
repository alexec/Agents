import AgentsKitCore
import Foundation

/// The little of the MCP events draft (`experimental-ext-triggers-events`, February 2026)
/// the daemon speaks (#383, contracts/mcp-events-client.md): poll mode only.
///
/// Every method and field name of the draft is in this one file, so a change to the draft
/// is one edit here and one in the CI watcher.
enum MCPEventsWire {
    /// The newest protocol version the daemon offers on an event connection, then the one
    /// it offers everywhere else. Either is taken back (research R2).
    static let protocolVersions = ["2026-07-28", "2025-06-18"]
    static let listMethod = "events/list"
    static let pollMethod = "events/poll"
    static let listChanged = "notifications/events/list_changed"
    static let capability = "events"
    static let pollMode = "poll"
}

/// One event a server offers, from `events/list`.
struct EventDefinition: Equatable, Sendable {
    var name: String
    var description: String?
    /// How it can be delivered: `poll`, `push`, `webhook`.
    var delivery: [String]
    /// Its filters, as JSON Schema. Checked with `JSONSchemaSubset`.
    var inputSchema: JSONValue?
    /// What its `data` holds. Not enforced: a payload is untrusted data whatever it says.
    var payloadSchema: JSONValue?

    init(name: String, description: String? = nil, delivery: [String] = [MCPEventsWire.pollMode],
         inputSchema: JSONValue? = nil, payloadSchema: JSONValue? = nil) {
        self.name = name
        self.description = description
        self.delivery = delivery
        self.inputSchema = inputSchema
        self.payloadSchema = payloadSchema
    }

    init?(_ raw: JSONValue) {
        guard let name = raw["name"]?.stringValue else { return nil }
        self.init(name: name, description: raw["description"]?.stringValue,
                  delivery: raw["delivery"]?.arrayValue?.compactMap(\.stringValue) ?? [],
                  inputSchema: raw["inputSchema"], payloadSchema: raw["payloadSchema"])
    }

    var wire: JSONValue {
        var object: [String: JSONValue] = ["name": .string(name), "delivery": .array(delivery.map(JSONValue.string))]
        if let description { object["description"] = .string(description) }
        if let inputSchema { object["inputSchema"] = inputSchema }
        if let payloadSchema { object["payloadSchema"] = payloadSchema }
        return .object(object)
    }

    var offersPoll: Bool { delivery.contains(MCPEventsWire.pollMode) }
}

/// `events/list`'s answer.
struct EventsListResult: Equatable, Sendable {
    var events: [EventDefinition]
    var nextCursor: String?
}

/// What `events/poll` is asked.
struct EventsPollRequest: Equatable, Sendable {
    var name: String
    var arguments: [String: JSONValue]
    /// `nil` asks to start from now.
    var cursor: String?
    var maxEvents = 50

    var wire: JSONValue {
        ["name": .string(name), "arguments": .object(arguments),
         "cursor": cursor.map(JSONValue.string) ?? .null, "maxEvents": .int(maxEvents)]
    }
}

/// One event from `events/poll`.
struct PolledEvent: Equatable, Sendable {
    /// The dedupe key. An event without one is dropped.
    var eventId: String?
    var name: String?
    var timestamp: String?
    var data: JSONValue?

    init(eventId: String?, name: String?, timestamp: String? = nil, data: JSONValue? = nil) {
        self.eventId = eventId
        self.name = name
        self.timestamp = timestamp
        self.data = data
    }

    init(_ raw: JSONValue) {
        self.init(eventId: raw["eventId"]?.stringValue, name: raw["name"]?.stringValue,
                  timestamp: raw["timestamp"]?.stringValue, data: raw["data"])
    }

    var wire: JSONValue {
        var object: [String: JSONValue] = [:]
        if let eventId { object["eventId"] = .string(eventId) }
        if let name { object["name"] = .string(name) }
        if let timestamp { object["timestamp"] = .string(timestamp) }
        if let data { object["data"] = data }
        return .object(object)
    }
}

/// `events/poll`'s answer.
struct EventsPollResult: Equatable, Sendable {
    var events: [PolledEvent]
    /// `nil` keeps the previous one.
    var cursor: String?
    var truncated: Bool
    var hasMore: Bool
    var nextPollMs: Int?

    init(events: [PolledEvent] = [], cursor: String? = nil, truncated: Bool = false, hasMore: Bool = false,
         nextPollMs: Int? = nil) {
        self.events = events
        self.cursor = cursor
        self.truncated = truncated
        self.hasMore = hasMore
        self.nextPollMs = nextPollMs
    }

    init(_ raw: JSONValue) {
        self.init(events: raw["events"]?.arrayValue?.map(PolledEvent.init) ?? [],
                  cursor: raw["cursor"]?.stringValue, truncated: raw["truncated"]?.boolValue ?? false,
                  hasMore: raw["hasMore"]?.boolValue ?? false, nextPollMs: raw["nextPollMs"]?.intValue)
    }

    var wire: JSONValue {
        var object: [String: JSONValue] = ["events": .array(events.map(\.wire)), "truncated": .bool(truncated),
                                           "hasMore": .bool(hasMore), "cursor": cursor.map(JSONValue.string) ?? .null]
        if let nextPollMs { object["nextPollMs"] = .int(nextPollMs) }
        return .object(object)
    }
}

/// What went wrong asking a server for events, as the draft's codes and the transport say it.
enum MCPEventsError: Error, Equatable, Sendable {
    /// `-32011`: the event is gone.
    case notFound(String)
    /// `-32012`: not allowed.
    case forbidden(String)
    /// `-32013`: rate limited; wait at least this long when it says.
    case resourceExhausted(retryAfterMs: Int?)
    /// `-32014`: `schema_changed` means list again.
    case unsupported(reason: String?, message: String)
    /// `-32602`: arguments the local check let through.
    case invalidParams(String)
    /// Any other error the server answered with.
    case serverError(code: Int, message: String)
    /// 401 or 403 over http.
    case needsSignIn
    /// Nothing answered, it ended, or it took longer than 15 s.
    case transport(String)
    case timedOut

    static let notFoundCode = -32011
    static let forbiddenCode = -32012
    static let exhaustedCode = -32013
    static let unsupportedCode = -32014
    static let invalidParamsCode = -32602

    /// From a client failure, with the error's `data` when the server gave it.
    init(_ failure: MCPClient.Failure) {
        switch failure {
        case .refused(let code, let message, let data):
            switch code {
            case Self.notFoundCode: self = .notFound(message)
            case Self.forbiddenCode: self = .forbidden(message)
            case Self.exhaustedCode: self = .resourceExhausted(retryAfterMs: data?["retryAfterMs"]?.intValue)
            case Self.unsupportedCode: self = .unsupported(reason: data?["reason"]?.stringValue, message: message)
            case Self.invalidParamsCode: self = .invalidParams(message)
            default: self = .serverError(code: code, message: message)
            }
        case .authRequired: self = .needsSignIn
        case .httpStatus(403): self = .needsSignIn
        case .httpStatus(let status) where (500..<600).contains(status): self = .transport("http \(status)")
        case .httpStatus(let status): self = .serverError(code: status, message: "http \(status)")
        case .timedOut: self = .timedOut
        case .unreachable(let why), .stopped(let why): self = .transport(why)
        case .sessionExpired: self = .transport("session expired")
        case .notMCP: self = .serverError(code: 0, message: "What came back was not MCP.")
        case .transportNotSupported: self = .serverError(code: 0, message: "It uses the old sse transport.")
        }
    }

    /// One word for the log, never the server's own text.
    var logWord: String {
        switch self {
        case .notFound: "eventNotOffered"
        case .forbidden: "refused"
        case .resourceExhausted: "rate limited"
        case .unsupported: "unsupported"
        case .invalidParams: "badArguments"
        case .serverError: "serverError"
        case .needsSignIn: "needsSignIn"
        case .transport: "unreachable"
        case .timedOut: "timed out"
        }
    }
}

/// A server's `events` capability from `initialize`.
struct EventsCapability: Equatable, Sendable {
    /// It may send `notifications/events/list_changed`.
    var listChanged: Bool
}
