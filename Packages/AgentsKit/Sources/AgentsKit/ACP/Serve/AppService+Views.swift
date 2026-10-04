import AgentsKitCore
import Foundation

extension AppService {
    /// Why a call of a tool with a view did nothing, in words for the agent.
    public struct ViewToolFailure: Error, ExpressibleByStringLiteral, Sendable {
        public let message: String
        public init(stringLiteral value: String) { message = value }
        public init(_ message: String) { self.message = message }
    }

    /// Where an agent's call of a tool with a view goes (#187): the tool's own name and
    /// its arguments, answered with the whole `CallToolResult`, `structuredContent` and
    /// all, since that is what the view and the model are both handed.
    public typealias ViewToolSink = @Sendable (String, JSONValue?) async -> Result<JSONValue, ViewToolFailure>

    /// A resource as `resources/list` gives it.
    static func listed(_ resource: AppViewCatalog.Resource) -> JSONValue {
        var fields: [String: JSONValue] = [
            "uri": .string(resource.uri), "name": .string(resource.name), "title": .string(resource.title),
            "description": .string(resource.description), "mimeType": .string(AppViewResourceType.html),
        ]
        if let meta = resource.meta { fields["_meta"] = meta }
        return .object(fields)
    }

    /// A resource as `resources/read` gives it.
    static func contents(_ resource: AppViewCatalog.Resource) -> JSONValue {
        var fields: [String: JSONValue] = [
            "uri": .string(resource.uri), "mimeType": .string(AppViewResourceType.html), "text": .string(resource.html),
        ]
        if let meta = resource.meta { fields["_meta"] = meta }
        return .object(fields)
    }
}
