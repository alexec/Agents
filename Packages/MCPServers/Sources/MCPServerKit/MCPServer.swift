import Foundation

/// A tool as `tools/list` gives it.
public struct Tool: Sendable {
    public var name: String
    public var title: String
    public var description: String
    public var inputSchema: Schema
    public var annotations: JSON?
    public var meta: JSON?

    public init(name: String, title: String, description: String, inputSchema: Schema,
                annotations: JSON? = nil, meta: JSON? = nil) {
        self.name = name
        self.title = title
        self.description = description
        self.inputSchema = inputSchema
        self.annotations = annotations
        self.meta = meta
    }

    public var json: JSON {
        var o: [String: JSON] = ["name": .string(name), "title": .string(title),
                                 "description": .string(description), "inputSchema": inputSchema.json]
        if let annotations { o["annotations"] = annotations }
        if let meta { o["_meta"] = meta }
        return .object(o)
    }
}

/// What a tool call answers: text for the model, and the same as structured content.
public enum ToolResult {
    public static func structured(_ value: JSON) -> JSON {
        ["content": [["type": "text", "text": .string(value.text)]], "structuredContent": value]
    }

    public static func text(_ text: String) -> JSON {
        ["content": [["type": "text", "text": .string(text)]]]
    }

    public static func error(_ message: String) -> JSON {
        ["content": [["type": "text", "text": .string(message)]], "isError": true]
    }
}

/// A resource, such as an MCP app's view, with its text: a static binary carries it inside.
public struct Resource: Sendable {
    public var uri: String
    public var name: String
    public var title: String
    public var description: String
    public var mimeType: String
    public var meta: JSON?
    public var text: String

    public init(uri: String, name: String, title: String, description: String, mimeType: String,
                meta: JSON? = nil, text: String) {
        self.uri = uri
        self.name = name
        self.title = title
        self.description = description
        self.mimeType = mimeType
        self.meta = meta
        self.text = text
    }

    /// As `resources/list` gives it, without its text.
    public var listed: JSON {
        var o: [String: JSON] = ["uri": .string(uri), "name": .string(name), "title": .string(title),
                                 "description": .string(description), "mimeType": .string(mimeType)]
        if let meta { o["_meta"] = meta }
        return .object(o)
    }

    /// As `resources/read` gives it.
    public var contents: JSON {
        var o: [String: JSON] = ["uri": .string(uri), "mimeType": .string(mimeType), "text": .string(text)]
        if let meta { o["_meta"] = meta }
        return .object(o)
    }
}

/// An event as `events/list` gives it (the events draft that the Agents daemon polls).
public struct Event: Sendable {
    public var name: String
    public var title: String
    public var description: String
    public var delivery: [String]
    public var inputSchema: Schema
    public var payloadSchema: JSON

    public init(name: String, title: String, description: String, delivery: [String] = ["poll"],
                inputSchema: Schema, payloadSchema: JSON) {
        self.name = name
        self.title = title
        self.description = description
        self.delivery = delivery
        self.inputSchema = inputSchema
        self.payloadSchema = payloadSchema
    }

    public var json: JSON {
        ["name": .string(name), "title": .string(title), "description": .string(description),
         "delivery": JSON(delivery), "inputSchema": inputSchema.json, "payloadSchema": payloadSchema]
    }
}

/// An MCP server over the methods every one of ours answers: `initialize`, `ping`, and the
/// lists and calls of its tools, resources and events. What is its own comes in as values and
/// closures; a method it does not have is -32601.
public struct MCPServer: RPCHandler {
    public struct Info: Sendable {
        public var name: String
        public var title: String
        public var version: String
        public init(name: String, title: String, version: String) {
            self.name = name
            self.title = title
            self.version = version
        }
    }

    /// Newest first; the first is offered to a client that asks for one not here.
    public static let protocolVersions = ["2026-07-28", "2025-11-25", "2025-06-18", "2025-03-26"]

    public var info: Info
    public var instructions: String
    public var tools: [Tool]
    public var resources: [Resource]
    public var events: [Event]
    /// The `extensions` capability, such as `io.modelcontextprotocol/ui` for a server with views.
    public var extensions: [String: JSON]
    /// Called with a tool that is listed and its raw arguments; checking them is its own.
    public var callTool: @Sendable (Tool, JSON?) async throws -> JSON
    /// Called with an event that is listed and the whole `events/poll` params.
    public var poll: @Sendable (Event, JSON) async throws -> JSON

    public init(info: Info, instructions: String, tools: [Tool] = [], resources: [Resource] = [],
                events: [Event] = [], extensions: [String: JSON] = [:],
                callTool: @escaping @Sendable (Tool, JSON?) async throws -> JSON = { tool, _ in
                    throw RPCError.invalidParams("no tool \(tool.name)")
                },
                poll: @escaping @Sendable (Event, JSON) async throws -> JSON = { event, _ in
                    throw RPCError(-32011, "no event \(event.name)")
                }) {
        self.info = info
        self.instructions = instructions
        self.tools = tools
        self.resources = resources
        self.events = events
        self.extensions = extensions
        self.callTool = callTool
        self.poll = poll
    }

    public var capabilities: JSON {
        var o: [String: JSON] = [:]
        if !tools.isEmpty { o["tools"] = [:] }
        if !resources.isEmpty { o["resources"] = [:] }
        if !events.isEmpty { o["events"] = ["listChanged": false] }
        if !extensions.isEmpty { o["extensions"] = .object(extensions) }
        return .object(o)
    }

    public func handle(method: String, params: JSON?) async throws -> JSON {
        switch method {
        case "initialize":
            let asked = params?["protocolVersion"]?.string
            let version = asked.flatMap { Self.protocolVersions.contains($0) ? $0 : nil } ?? Self.protocolVersions[0]
            return [
                "protocolVersion": .string(version),
                "capabilities": capabilities,
                "serverInfo": ["name": .string(info.name), "title": .string(info.title), "version": .string(info.version)],
                "instructions": .string(instructions),
            ]
        case "ping":
            return [:]
        case "tools/list":
            return ["tools": .array(tools.map(\.json))]
        case "tools/call":
            let name = params?["name"]?.string
            guard let tool = tools.first(where: { $0.name == name }) else {
                throw RPCError.invalidParams("no tool \(name ?? "undefined")")
            }
            return try await callTool(tool, params?["arguments"])
        case "resources/list":
            return ["resources": .array(resources.map(\.listed))]
        case "resources/templates/list":
            return ["resourceTemplates": []]
        case "resources/read":
            let uri = params?["uri"]?.string
            guard let resource = resources.first(where: { $0.uri == uri }) else {
                throw RPCError(-32002, "no resource \(uri ?? "undefined")")
            }
            return ["contents": [resource.contents]]
        case "events/list":
            return ["events": .array(events.map(\.json))]
        case "events/poll":
            let name = params?["name"]?.string
            guard let event = events.first(where: { $0.name == name }) else {
                throw RPCError(-32011, "no event \(name ?? "undefined"); this server offers \(events.map(\.name).joined(separator: ", "))")
            }
            return try await poll(event, params ?? [:])
        default:
            throw RPCError.methodNotFound(method)
        }
    }
}
