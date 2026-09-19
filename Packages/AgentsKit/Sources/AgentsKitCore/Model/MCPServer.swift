import Foundation

/// An MCP server attached to an agent, sent when its session is made.
///
/// Three transports, because that is what the protocol has and what the runtimes
/// advertise: `stdio` is baseline, `http` and `sse` are advertised by all three.
public struct MCPServer: Codable, Hashable, Sendable, Identifiable {
    public var name: String
    public var transport: Transport

    public var id: String { name }

    public enum Transport: Codable, Hashable, Sendable {
        case stdio(command: String, args: [String], env: [String: String])
        case http(url: String, headers: [String: String])
        case sse(url: String, headers: [String: String])
    }

    public init(name: String, transport: Transport) {
        self.name = name
        self.transport = transport
    }

    public var wire: JSONValue {
        switch transport {
        case .stdio(let command, let args, let env):
            return ["name": .string(name), "command": .string(command),
                    "args": .array(args.map(JSONValue.string)),
                    "env": .array(env.map { ["name": .string($0.key), "value": .string($0.value)] })]
        case .http(let url, let headers):
            return ["type": "http", "name": .string(name), "url": .string(url),
                    "headers": Self.headerList(headers)]
        case .sse(let url, let headers):
            return ["type": "sse", "name": .string(name), "url": .string(url),
                    "headers": Self.headerList(headers)]
        }
    }

    private static func headerList(_ headers: [String: String]) -> JSONValue {
        .array(headers.map { ["name": .string($0.key), "value": .string($0.value)] })
    }
}
