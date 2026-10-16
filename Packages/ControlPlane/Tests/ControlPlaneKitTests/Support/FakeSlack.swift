import AgentsKitCore
@testable import ControlPlaneKit
import Foundation

/// Slack, faked (#1009): the Web API methods the channel calls, and a Socket Mode socket a
/// test pushes envelopes into and reads acknowledgements from.
final class FakeSlack: SlackTransport, @unchecked Sendable {
    struct Call: Sendable {
        var method: String
        var token: String
        var body: [String: JSONValue]
    }

    private let lock = NSLock()
    private var calls: [Call] = []
    private var sockets: [FakeSlackSocket] = []
    private var nextTS = 1
    /// Slack's `error` for a method, to refuse it.
    var refuse: [String: String] = [:]

    var made: [Call] { lock.withLock { calls } }
    func made(_ method: String) -> [Call] { made.filter { $0.method == method } }
    var socket: FakeSlackSocket? { lock.withLock { sockets.last } }
    var connections: Int { lock.withLock { sockets.count } }

    func call(_ method: String, token: String, body: [String: JSONValue]) async throws -> JSONValue {
        let refused: String? = lock.withLock {
            calls.append(Call(method: method, token: token, body: body))
            return refuse[method]
        }
        if let refused { throw SlackFailure.said(refused, method: method) }
        switch method {
        case "apps.connections.open":
            return ["ok": true, "url": "wss://wss-primary.slack.com/link/?ticket=t"]
        case "conversations.open":
            return ["ok": true, "channel": ["id": "D1"]]
        case "chat.postMessage":
            let ts = lock.withLock { () -> String in
                defer { nextTS += 1 }
                let ts = "1700000000.\(100000 + nextTS)"
                if body["thread_ts"] == nil { questions.append(ts) }
                return ts
            }
            return ["ok": true, "ts": .string(ts), "channel": body["channel"] ?? "D1"]
        default:
            return ["ok": true]
        }
    }

    func connect(_ url: URL) async throws -> any LineTransport {
        let socket = FakeSlackSocket()
        lock.withLock { sockets.append(socket) }
        socket.push(["type": "hello", "num_connections": 1])
        return socket
    }

    /// The `ts` of each question sent, not of notes in threads.
    private var questions: [String] = []
    var lastTS: String? { lock.withLock { questions.last } }

    // What Slack would send.

    func press(_ value: String, in key: String, by user: String) {
        socket?.push(["envelope_id": .string(UUID().uuidString), "type": "interactive", "payload": [
            "type": "block_actions", "user": ["id": .string(user)],
            "actions": [["block_id": .string(key), "action_id": "option-0", "value": .string(value)]],
        ]])
    }

    func reply(_ text: String, inThread ts: String?, by user: String, bot: Bool = false) {
        var event: [String: JSONValue] = ["type": "message", "channel": "D1", "user": .string(user), "text": .string(text),
                                          "ts": "1700000099.000001"]
        if let ts { event["thread_ts"] = .string(ts) }
        if bot { event["bot_id"] = "B1" }
        socket?.push(["envelope_id": .string(UUID().uuidString), "type": "events_api", "payload": ["event": .object(event)]])
    }
}

final class FakeSlackSocket: LineTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var written: [String] = []
    private let stream: AsyncThrowingStream<String, any Error>
    private let continuation: AsyncThrowingStream<String, any Error>.Continuation

    init() {
        (stream, continuation) = AsyncThrowingStream.makeStream()
    }

    var acks: [String] {
        lock.withLock { written }.compactMap {
            (try? JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)))?["envelope_id"]?.stringValue
        }
    }

    func push(_ envelope: JSONValue) {
        continuation.yield(String(decoding: try! JSONEncoder().encode(envelope), as: UTF8.self))
    }

    func write(line: String) throws { lock.withLock { written.append(line) } }
    func lines() -> AsyncThrowingStream<String, any Error> { stream }
    func close() { continuation.finish() }
}
