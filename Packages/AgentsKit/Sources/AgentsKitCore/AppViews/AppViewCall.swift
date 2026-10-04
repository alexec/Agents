import Foundation

/// One call of a tool that has a view (#187, MCP Apps): what the chat draws the view
/// from, as the daemon saw the call.
///
/// The #186 probe found that no runtime tells the app a tool has a `ui://` view, or passes
/// the result's `structuredContent` on whole. But the app's own `agents` server *is* the
/// daemon, so the daemon writes this itself as the call arrives and again as it ends: the
/// arguments, then the whole `CallToolResult`. Nothing in it comes from the runtime's
/// account of the call, so it is the same on every runtime.
///
/// Appended, like every entry: the entries for one call share `id`, and the latest one
/// is the call as it stands. The chat draws the view once, where the call began.
public struct AppViewCall: Codable, Hashable, Sendable, Identifiable {
    public enum State: String, Codable, Hashable, Sendable {
        /// Called, and not answered yet: the view has its input and waits for the result.
        case running
        /// Answered: `result` is the whole `CallToolResult`.
        case done
        /// The turn was stopped before the call was answered.
        case cancelled
    }

    public var id: UUID
    /// The server whose view it is. Only the app's own, `agents`, until third-party views.
    public var server: String
    /// The tool's own name on that server, unprefixed.
    public var tool: String
    /// The `ui://` resource the view is drawn from.
    public var resourceURI: String
    public var arguments: JSONValue?
    public var result: JSONValue?
    public var state: State
    /// Why it was cancelled, for `ui/notifications/tool-cancelled`.
    public var reason: String?

    public init(id: UUID = UUID(), server: String = AppTool.serverName, tool: String,
                resourceURI: String, arguments: JSONValue? = nil, result: JSONValue? = nil,
                state: State = .running, reason: String? = nil) {
        self.id = id
        self.server = server
        self.tool = tool
        self.resourceURI = resourceURI
        self.arguments = arguments
        self.result = result
        self.state = state
        self.reason = reason
    }

    enum CodingKeys: String, CodingKey {
        case id, server, tool, resourceURI = "resourceUri", arguments, result, state, reason
    }

    /// The result's text, for the places that read rather than draw: what the model was
    /// told, joined.
    public var resultText: String? {
        let texts = result?["content"]?.arrayValue?.compactMap { block -> String? in
            block["type"]?.stringValue == "text" ? block["text"]?.stringValue : nil
        } ?? []
        return texts.isEmpty ? nil : texts.joined(separator: "\n")
    }
}
