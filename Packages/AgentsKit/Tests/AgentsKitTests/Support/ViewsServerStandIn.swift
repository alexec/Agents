import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import AgentsKit
@testable import AgentsKitCore

/// A person's MCP Apps server over streamable http, standing in for an ext-apps example
/// (#191): a weather tool with a view, an app-only tool, a model-only tool, and the view's
/// HTML declaring one domain.
final class ViewsServerStandIn: @unchecked Sendable {
    private let lock = NSLock()
    private var methods: [String] = []
    private var sessions = 0
    private var html: String
    var seen: [String] { lock.withLock { methods } }
    var connections: Int { lock.withLock { sessions } }

    init(html: String = "<p>weather</p>") { self.html = html }

    func changeHTML(_ text: String) { lock.withLock { html = text } }

    var send: MCPClient.HTTPSend {
        { [self] request in try self.answer(request) }
    }

    static let tools: JSONValue = [
        ["name": "weather", "annotations": ["readOnlyHint": true],
         "_meta": ["ui": ["resourceUri": "ui://kite/weather", "visibility": ["model", "app"]]]],
        ["name": "refresh", "_meta": ["ui": ["visibility": ["app"]]]],
        ["name": "secret_model_tool", "_meta": ["ui": ["visibility": ["model"]]]],
    ]

    private func answer(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        let body = request.httpBody.flatMap { try? JSONValue.parse($0) }
        let method = request.httpMethod == "POST" ? body?["method"]?.stringValue ?? "?" : request.httpMethod ?? "?"
        let html = lock.withLock { () -> String in
            methods.append(method)
            if method == "initialize" { sessions += 1 }
            return self.html
        }
        func reply(_ status: Int, _ result: JSONValue? = nil, session: Bool = false) throws -> (Data, HTTPURLResponse) {
            var headers = ["Content-Type": "application/json"]
            if session { headers["Mcp-Session-Id"] = "v-1" }
            let data = try result.map {
                try JSONEncoder().encode(JSONValue.object(["jsonrpc": "2.0", "id": body?["id"] ?? .null, "result": $0]))
            } ?? Data()
            return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!)
        }
        switch method {
        case "initialize":
            return try reply(200, ["protocolVersion": "2025-06-18", "capabilities": [:],
                                   "serverInfo": ["name": "kite", "version": "1"]], session: true)
        case "tools/list":
            return try reply(200, ["tools": Self.tools])
        case "resources/list":
            return try reply(200, ["resources": [["uri": "ui://kite/weather", "name": "Weather",
                                                  "mimeType": "text/html;profile=mcp-app"]]])
        case "resources/read":
            return try reply(200, ["contents": [[
                "uri": "ui://kite/weather", "mimeType": "text/html;profile=mcp-app", "text": .string(html),
                "_meta": ["ui": ["csp": ["connectDomains": ["https://api.kite.example"]]]],
            ]]])
        case "tools/call":
            let name = body?["params"]?["name"]?.stringValue ?? ""
            return try reply(200, ["content": [["type": "text", "text": .string("called \(name)")]],
                                   "structuredContent": ["called": .string(name)]])
        case "DELETE":
            return try reply(200)
        default:
            return try reply(body?["id"] == nil ? 202 : 404)
        }
    }
}
