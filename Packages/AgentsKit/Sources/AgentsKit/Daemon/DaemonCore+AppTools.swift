import Foundation

/// Where a suggested prompt comes from.
///
/// The app hands every session an MCP server of its own. It is not a process we start:
/// the runtime starts it, the way it starts any stdio MCP server, by running the same
/// helper binary the daemon is running with `mcp <token>` after it. That helper does
/// nothing but speak MCP on its stdin and pass what it hears back down the daemon's
/// socket, which is why the whole of the decision-making is here and testable.
///
/// The token is what makes the call belong to an agent. It is minted per session,
/// bound when the agent exists, and dropped when the session ends, so a helper left
/// behind by a dead runtime cannot post into a conversation it is no longer part of.
extension DaemonCore {
    /// The MCP server every agent is given, beside whatever the user attached.
    ///
    /// The helper is told where this daemon lives rather than left to work it out. A
    /// helper that guesses at the usual place talks to whichever daemon happens to be
    /// there, which is right in the app and wrong everywhere else, tests included.
    func suggestionServer(token: String) -> MCPServer {
        MCPServer(name: "agents",
                  transport: .stdio(command: Self.helperPath,
                                    args: ["mcp", token],
                                    env: [Self.rootVariable: locations.root.path]))
    }

    static let rootVariable = "AGENTS_ROOT"

    /// Where the helper looks for the daemon that started it.
    public static var helperLocations: StoreLocations {
        guard let root = ProcessInfo.processInfo.environment[rootVariable], !root.isEmpty else {
            return .default
        }
        return StoreLocations(root: URL(filePath: root))
    }

    /// The binary the runtime is told to run. The daemon's own path: one build, one
    /// signature, and no second thing to install or keep in step.
    ///
    /// `AGENTS_MCP_HELPER` names it instead, for the live tests, which run inside a
    /// test binary rather than inside the daemon.
    static var helperPath: String {
        if let named = ProcessInfo.processInfo.environment["AGENTS_MCP_HELPER"], !named.isEmpty {
            return named
        }
        return ProcessInfo.processInfo.arguments.first.map {
            URL(fileURLWithPath: $0).resolvingSymlinksInPath().path
        } ?? "agentsd"
    }

    func mintSuggestionToken() -> String {
        UUID().uuidString
    }

    /// Say which agent a token speaks for. Called once the agent exists, which is
    /// after the session that carries the token was made.
    func bindSuggestionToken(_ token: String, to agentID: UUID) {
        // One live token per agent. A session made again for the same agent replaces
        // the old one rather than leaving it answerable.
        for (existing, id) in suggestionTokens where id == agentID && existing != token {
            suggestionTokens.removeValue(forKey: existing)
        }
        suggestionTokens[token] = agentID
    }

    func dropSuggestionTokens(for agentID: UUID) {
        for (token, id) in suggestionTokens where id == agentID {
            suggestionTokens.removeValue(forKey: token)
        }
    }

    /// An agent has said what you might want to ask next.
    public func suggestPrompts(_ request: DaemonAPI.SuggestPromptsRequest) async throws -> String {
        guard let agentID = suggestionTokens[request.token], var agent = agents[agentID] else {
            // Said plainly, because the agent reads this. A runtime that kept a helper
            // alive past its session gets told why nothing happened.
            throw JSONRPCError(code: DaemonAPI.Failure.noSuchAgent,
                               message: "That conversation is not open any more, so the suggestions were not shown.")
        }
        let prompts = Array(request.prompts.prefix(SuggestedPrompt.limit))
        guard !prompts.isEmpty else {
            throw JSONRPCError(code: JSONRPCError.invalidParams, message: "No suggestions were sent.")
        }
        agent.suggestedPrompts = prompts
        changed(agent)
        return prompts.count == 1
            ? "Shown above the prompt. The person may tap it, edit it, or ignore it."
            : "\(prompts.count) shown above the prompt. The person may tap one, edit it, or ignore them."
    }

    /// The turn they belonged to is over. Anything the user sends is the answer to
    /// what was suggested, whether they tapped a chip or typed past it.
    func clearSuggestions(for agentID: UUID) {
        guard var agent = agents[agentID], !agent.suggestedPrompts.isEmpty else { return }
        agent.suggestedPrompts = []
        changed(agent)
    }

    /// Answer the permission question for our own tool ourselves.
    ///
    /// Copilot asks before every tool call, including this one. A sheet asking whether
    /// the app may show the app's own suggestions is a question with no information in
    /// it, and asked once a turn it would be worse than not having the feature. It is
    /// allowed only where the runtime offered allowing it, and only for this tool.
    func autoAllowed(_ request: PermissionRequest) -> PermissionOption? {
        guard request.toolCall.isSuggestingPrompts else { return nil }
        return request.options.first { $0.kind == .allowAlways }
            ?? request.options.first { $0.kind == .allowOnce }
    }
}
