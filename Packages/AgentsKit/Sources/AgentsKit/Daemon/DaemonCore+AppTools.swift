import Foundation

/// Where a suggested prompt, and a file the agent wants looked at, come from.
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
    func appServer(token: String) -> MCPServer {
        MCPServer(name: "agents",
                  transport: .stdio(command: Self.helperPath,
                                    args: ["mcp", token],
                                    env: [StoreLocations.rootVariable: locations.root.path]))
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

    func mintAppToken() -> String {
        UUID().uuidString
    }

    /// Say which agent a token speaks for. Called once the agent exists, which is
    /// after the session that carries the token was made.
    func bindAppToken(_ token: String, to agentID: UUID) {
        // One live token per agent. A session made again for the same agent replaces
        // the old one rather than leaving it answerable.
        for (existing, id) in appTokens where id == agentID && existing != token {
            appTokens.removeValue(forKey: existing)
        }
        appTokens[token] = agentID
    }

    func dropAppTokens(for agentID: UUID) {
        for (token, id) in appTokens where id == agentID {
            appTokens.removeValue(forKey: token)
        }
    }

    /// An agent has said what you might want to ask next.
    public func suggestPrompts(_ request: DaemonAPI.SuggestPromptsRequest) async throws -> String {
        guard let agentID = appTokens[request.token], var agent = agents[agentID] else {
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

    /// An agent has asked that a file be put in front of the user.
    ///
    /// Three things are checked here rather than in the window, because the window is
    /// not the only thing that could be listening and because the agent deserves a
    /// straight answer either way: the token still speaks for an agent, the path is
    /// inside that agent's folders, and the file is there to be read. Nothing is
    /// stored: a file worth looking at now is not worth reopening a week from now, so
    /// this goes out as an event and is gone.
    public func showFile(_ request: DaemonAPI.ShowFileRequest) async throws -> String {
        guard let agentID = appTokens[request.token], let agent = agents[agentID] else {
            throw JSONRPCError(code: DaemonAPI.Failure.noSuchAgent,
                               message: "That conversation is not open any more, so the file was not shown.")
        }
        let scope = agent.folderScope
        guard scope.allows(request.file.path) else {
            // The same sentence a refused read gets. An agent that is told the rule
            // once does not need to be told it differently by every door.
            throw JSONRPCError(code: JSONRPCError.invalidParams,
                               message: scope.refusal(for: request.file.path))
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: request.file.path, isDirectory: &isDirectory) else {
            throw JSONRPCError(code: JSONRPCError.invalidParams,
                               message: "There is no file at \(request.file.path).")
        }
        guard !isDirectory.boolValue else {
            throw JSONRPCError(code: JSONRPCError.invalidParams,
                               message: "\(request.file.path) is a folder, and this shows a file.")
        }
        guard connectionCount > 0 else {
            // Told, not swallowed. The agent may be working for somebody who closed
            // the window an hour ago, and saying "shown" to that would be a lie.
            throw JSONRPCError(code: DaemonAPI.Failure.noSuchAgent,
                               message: "No window is open, so there was nowhere to show it.")
        }
        broadcast(DaemonAPI.Notification.agentShowFile,
                  DaemonAPI.ShowFileNotification(agentID: agentID, file: request.file))
        let place = request.file.line.map { " at line \($0)" } ?? ""
        return """
            \(request.file.name) is open\(place) in the files pane beside this \
            conversation. Say what they are looking at; do not paste the file back.
            """
    }

    /// The turn they belonged to is over. Anything the user sends is the answer to
    /// what was suggested, whether they tapped a chip or typed past it.
    func clearSuggestions(for agentID: UUID) {
        guard var agent = agents[agentID], !agent.suggestedPrompts.isEmpty else { return }
        agent.suggestedPrompts = []
        changed(agent)
    }

    /// Answer the permission question for our own tools ourselves.
    ///
    /// Copilot asks before every tool call, including these. A sheet asking whether
    /// the app may show the app's own suggestions is a question with no information in
    /// it, and asked once a turn it would be worse than not having the feature. The
    /// same goes for opening a file in a read-only pane, in a folder the agent can
    /// already read, in the window the person is looking at. It is allowed only where
    /// the runtime offered allowing it, and only for these two tools.
    func autoAllowed(_ request: PermissionRequest) -> PermissionOption? {
        guard request.toolCall.isTheApps else { return nil }
        return request.options.first { $0.kind == .allowAlways }
            ?? request.options.first { $0.kind == .allowOnce }
    }
}
