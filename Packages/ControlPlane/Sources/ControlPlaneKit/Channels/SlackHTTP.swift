import AgentsKitCore
import AsyncHTTPClient
import ControlDial
import Foundation
import NIOCore
import NIOHTTP1

/// Slack itself: the Web API over HTTPS, and Socket Mode's WebSocket dialled out (#1009).
public struct SlackHTTP: SlackTransport {
    let client: HTTPClient
    let base: String

    public init(client: HTTPClient = .shared, base: String = "https://slack.com/api/") {
        self.client = client
        self.base = base
    }

    public func call(_ method: String, token: String, body: [String: JSONValue]) async throws -> JSONValue {
        var request = HTTPClientRequest(url: base + method)
        request.method = .POST
        request.headers.add(name: "authorization", value: "Bearer \(token)")
        request.headers.add(name: "content-type", value: "application/json; charset=utf-8")
        request.body = .bytes(ByteBuffer(bytes: try JSONEncoder().encode(JSONValue.object(body))))
        let response: HTTPClientResponse
        do {
            response = try await client.execute(request, timeout: .seconds(20))
        } catch {
            throw SlackFailure("Slack could not be reached: \(error)")
        }
        var buffer = try await response.body.collect(upTo: 4 << 20)
        let bytes = buffer.readBytes(length: buffer.readableBytes) ?? []
        guard response.status == .ok, let reply = try? JSONDecoder().decode(JSONValue.self, from: Data(bytes)) else {
            throw SlackFailure("Slack answered \(method) with \(response.status.code).")
        }
        guard reply["ok"] == .bool(true) else {
            throw SlackFailure.said(reply["error"]?.stringValue ?? "an unknown error", method: method)
        }
        return reply
    }

    public func connect(_ url: URL) async throws -> any LineTransport {
        try await ControlDial.connect(url, ownPath: true)
    }
}
