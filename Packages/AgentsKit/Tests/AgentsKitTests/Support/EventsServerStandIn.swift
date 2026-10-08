import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import AgentsKit
@testable import AgentsKitCore

/// An MCP server offering events in poll mode (#383, contracts/mcp-events-client.md), over
/// streamable http, with a feed a test raises events into.
///
/// Its cursor is the index into the feed of each event name. `cursor: null` starts from
/// now, as the draft says, unless `backlogOnFirstPoll` is set to stand in for a server
/// that answers it with a backlog. An event appended with `for:` arguments goes only to
/// polls whose arguments hold those values, as a server's own filtering would.
///
/// Several can be routed side by side by host (`<name>.example`) with `route(_:)`.
final class EventsServerStandIn: @unchecked Sendable {
    struct Poll: Equatable {
        var name: String
        var arguments: [String: JSONValue]
        var cursor: String?
    }

    struct Scripted {
        var event: PolledEvent
        var only: [String: JSONValue]
    }

    let name: String
    private let lock = NSLock()
    private var definitionsHeld: [EventDefinition]
    private var feed: [String: [Scripted]] = [:]
    private var polled: [Poll] = []
    private var lists = 0
    private var sessions = 0
    private var failure: (code: Int, message: String, data: JSONValue?)?
    private var failOnce = false
    private var down = false
    private var truncatedNext = false
    private var hintNext: Int?
    private var hint: Int?
    private var events = true
    var backlogOnFirstPoll = false

    var url: String { "https://\(name).example/mcp" }

    init(name: String = "ci", events: [EventDefinition] = [EventsServerStandIn.checksFailed]) {
        self.name = name
        self.definitionsHeld = events
    }

    static let checksFailed = EventDefinition(
        name: "checks.failed", description: "A pull request's checks finished with a failure.",
        delivery: ["poll"],
        inputSchema: ["type": "object", "properties": ["repo": ["type": "string"], "branch": ["type": "string"]],
                      "required": ["repo"]],
        payloadSchema: ["type": "object"])

    static let prMerged = EventDefinition(
        name: "pr.merged", delivery: ["poll"],
        inputSchema: ["type": "object", "properties": ["repo": ["type": "string"]]])

    // MARK: What a test sets

    var definitions: [EventDefinition] {
        get { lock.withLock { definitionsHeld } }
        set { lock.withLock { definitionsHeld = newValue } }
    }

    /// No `events` capability at all.
    func offerNoEvents() { lock.withLock { events = false } }

    /// An event into the feed, for every poll or only polls with `for`'s values.
    func raise(_ id: String, name: String = "checks.failed", data: JSONValue = ["pr": 1],
               for only: [String: JSONValue] = [:]) {
        let event = PolledEvent(eventId: id, name: name, timestamp: "2026-10-06T12:05:00Z", data: data)
        lock.withLock { feed[name, default: []].append(Scripted(event: event, only: only)) }
    }

    /// An event as given, missing fields and all.
    func raiseRaw(_ event: PolledEvent, under name: String = "checks.failed") {
        lock.withLock { feed[name, default: []].append(Scripted(event: event, only: [:])) }
    }

    /// Answer every poll with this JSON-RPC error until `recover()`, or only the next one.
    func fail(code: Int, message: String = "no", data: JSONValue? = nil, once: Bool = false) {
        lock.withLock {
            failure = (code, message, data)
            failOnce = once
        }
    }

    /// Nothing answers at its address until `recover()`.
    func goDown() { lock.withLock { down = true } }

    func recover() {
        lock.withLock {
            down = false
            failure = nil
        }
    }

    func truncateNextPoll() { lock.withLock { truncatedNext = true } }

    /// `nextPollMs` on every answer from now; nil leaves it out.
    func hint(nextPollMs: Int?) { lock.withLock { hint = nextPollMs } }

    // MARK: What a test reads

    var polls: [Poll] { lock.withLock { polled } }
    var listCount: Int { lock.withLock { lists } }
    var connections: Int { lock.withLock { sessions } }

    func pollCount(_ name: String = "checks.failed", arguments: [String: JSONValue]? = nil) -> Int {
        polls.filter { $0.name == name && (arguments == nil || $0.arguments == arguments) }.count
    }

    // MARK: The wire

    var send: MCPClient.HTTPSend {
        { [self] request in try self.answer(request) }
    }

    /// One `HTTPSend` for several, by host.
    static func route(_ stands: [EventsServerStandIn]) -> MCPClient.HTTPSend {
        { request in
            guard let stand = stands.first(where: { request.url?.host == "\($0.name).example" }) else {
                throw URLError(.cannotFindHost)
            }
            return try stand.answer(request)
        }
    }

    private func answer(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        if lock.withLock({ down }) { throw URLError(.cannotConnectToHost) }
        let body = request.httpBody.flatMap { try? JSONValue.parse($0) }
        let method = request.httpMethod == "POST" ? body?["method"]?.stringValue ?? "?" : request.httpMethod ?? "?"
        func reply(_ status: Int, result: JSONValue? = nil, error: JSONValue? = nil, session: Bool = false) throws
            -> (Data, HTTPURLResponse) {
            var headers = ["Content-Type": "application/json"]
            if session { headers["Mcp-Session-Id"] = "e-1" }
            var message: [String: JSONValue] = ["jsonrpc": "2.0", "id": body?["id"] ?? .null]
            if let result { message["result"] = result }
            if let error { message["error"] = error }
            let data = result == nil && error == nil ? Data() : try JSONEncoder().encode(JSONValue.object(message))
            return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                          headerFields: headers)!)
        }
        switch method {
        case "initialize":
            let offers = lock.withLock { () -> Bool in
                sessions += 1
                return events
            }
            let capabilities: JSONValue = offers ? ["events": ["listChanged": true]] : [:]
            return try reply(200, result: ["protocolVersion": "2026-07-28", "capabilities": capabilities,
                                           "serverInfo": ["name": .string(name), "version": "1"]], session: true)
        case "events/list":
            let (offers, definitions) = lock.withLock { () -> (Bool, [EventDefinition]) in
                lists += 1
                return (events, definitionsHeld)
            }
            guard offers else { return try reply(200, error: ["code": -32601, "message": "Method not found"]) }
            return try reply(200, result: ["events": .array(definitions.map(\.wire))])
        case "events/poll":
            let params = body?["params"]
            let name = params?["name"]?.stringValue ?? ""
            let arguments = params?["arguments"]?.objectValue ?? [:]
            let cursor = params?["cursor"]?.stringValue
            let maxEvents = params?["maxEvents"]?.intValue ?? 50
            return try lock.withLock { () throws -> (Data, HTTPURLResponse) in
                polled.append(Poll(name: name, arguments: arguments, cursor: cursor))
                if let failure {
                    if failOnce { self.failure = nil }
                    var error: [String: JSONValue] = ["code": .int(failure.code), "message": .string(failure.message)]
                    if let data = failure.data { error["data"] = data }
                    return try reply(200, error: .object(error))
                }
                let all = feed[name] ?? []
                var start: Int
                if let cursor { start = Int(cursor) ?? 0 } else { start = backlogOnFirstPoll ? 0 : all.count }
                start = min(start, all.count)
                let rest = all[start...].enumerated()
                var given: [PolledEvent] = []
                var end = start
                for (offset, item) in rest {
                    if given.count == maxEvents { break }
                    end = start + offset + 1
                    if item.only.allSatisfy({ arguments[$0.key] == $0.value }) { given.append(item.event) }
                }
                let truncated = truncatedNext
                truncatedNext = false
                let result = EventsPollResult(events: given, cursor: String(end), truncated: truncated,
                                              hasMore: end < all.count, nextPollMs: hint)
                return try reply(200, result: result.wire)
            }
        case "notifications/initialized", "DELETE":
            return try reply(202)
        default:
            return try reply(200, error: ["code": -32601, "message": "Method not found"])
        }
    }
}
