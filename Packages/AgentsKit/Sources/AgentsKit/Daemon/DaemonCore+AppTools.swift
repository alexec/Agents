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
    /// the runtime offered allowing it, and only for those two tools.
    ///
    /// Not the workflow tool, which is the app's own and is the opposite case: writing
    /// a file that starts agents unattended is a question worth asking. Its own
    /// confirmation is raised by the daemon rather than left to the runtime, because
    /// Copilot asks before every tool call and the Claude adapter frequently asks
    /// before none — waiting for them would be strict under one and wide open under
    /// the other.
    func autoAllowed(_ request: PermissionRequest) -> PermissionOption? {
        guard request.toolCall.isAutoAllowable else { return nil }
        return request.options.first { $0.kind == .allowAlways }
            ?? request.options.first { $0.kind == .allowOnce }
    }
}

/// The workflow tool: what an agent may do to its own project's standing arrangements.
///
/// Reading asks nobody. Writing asks the person, and the question comes from here
/// rather than from the runtime — see `autoAllowed` above for why that matters.
extension DaemonCore {
    /// How long a write waits for an answer before giving up.
    ///
    /// A runtime blocked on a question nobody is going to answer is a conversation that
    /// never ends. Two minutes is long enough to read a prompt and short enough that an
    /// agent is not left holding a promise after somebody has walked away.
    static let workflowConfirmationTimeout = Duration.seconds(120)

    public func manageWorkflows(_ request: DaemonAPI.ManageWorkflowsRequest) async throws -> String {
        guard let agentID = appTokens[request.token], let agent = agents[agentID] else {
            throw JSONRPCError(code: DaemonAPI.Failure.noSuchAgent,
                               message: "That conversation is not open any more, so nothing was changed.")
        }
        // The project is the agent's own folder. There is deliberately no parameter for
        // naming a different one: the token is what makes a call belong to an agent, and
        // that is what scopes this.
        let project = Project.standardize(agent.cwd)

        switch request.action {
        case .list:
            return listWorkflowsForAgent(in: project)
        case .read:
            return try readWorkflowForAgent(request.workflowID, in: project)
        case .write:
            return try await writeWorkflowForAgent(request, in: project, agentID: agentID)
        case .remove:
            return try await removeWorkflowForAgent(request.workflowID, in: project, agentID: agentID)
        }
    }

    // MARK: Reading, which asks nobody

    private func listWorkflowsForAgent(in project: URL) -> String {
        let listed = allWorkflows(in: project)
        guard !listed.isEmpty else {
            return """
                This project has no workflows yet. They live in \
                \(WorkflowFile.folderName), one Markdown file each.
                """
        }
        let lines = listed.map { summary -> String in
            var line = "- \(summary.workflowID): \(summary.workflow.summary)"
            if summary.isPaused { line += " [paused]" }
            if let outcome = summary.lastOutcome { line += " — \(outcome.summary)" }
            return line
        }
        return ([listed.count == 1 ? "1 workflow:" : "\(listed.count) workflows:"] + lines)
            .joined(separator: "\n")
    }

    private func readWorkflowForAgent(_ workflowID: String?, in project: URL) throws -> String {
        let url = try workflowURL(workflowID, in: project)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw JSONRPCError(code: DaemonAPI.Failure.noSuchWorkflow,
                               message: "There is no workflow called \(workflowID ?? "") in this project.")
        }
        return text
    }

    // MARK: Writing, which does not

    private func writeWorkflowForAgent(_ request: DaemonAPI.ManageWorkflowsRequest,
                                       in project: URL, agentID: UUID) async throws -> String {
        let url = try workflowURL(request.workflowID, in: project)
        guard let content = request.content, !content.isEmpty else {
            throw JSONRPCError(code: JSONRPCError.invalidParams,
                               message: "Nothing was written: `content` has to be the whole file.")
        }

        // Parsed before anybody is asked. Raising a confirmation for a file that could
        // never fire spends the one moment of the reader's attention this feature gets,
        // and tells the agent nothing it could act on.
        let workflowID = url.deletingPathExtension().lastPathComponent
        let parsed = WorkflowFile.parse(content, workflowID: workflowID, in: project)
        if case .unreadable(let why) = parsed.problem {
            throw JSONRPCError(code: DaemonAPI.Failure.workflowUnreadable,
                               message: "That front matter could not be read: \(why). Nothing was written.")
        }

        let exists = FileManager.default.fileExists(atPath: url.path)
        let allowed = try await askAboutWorkflow(
            DaemonAPI.WorkflowConfirmation(
                agentID: agentID, folder: project, workflowID: workflowID,
                action: exists ? .update : .create,
                summary: parsed.summary, prompt: parsed.prompt))
        guard allowed else {
            throw JSONRPCError(code: DaemonAPI.Failure.notConfirmed,
                               message: "They declined, so nothing was written.")
        }

        try FileManager.default.createDirectory(at: WorkflowFile.folder(in: project),
                                                withIntermediateDirectories: true)
        // Written whole, exactly as it was handed over. Nothing is re-serialised from
        // the parsed form, which is what makes a key this version does not know survive
        // being written by an agent running against a later one.
        try Data(content.utf8).write(to: url, options: .atomic)
        rescanWorkflows(in: project)
        return """
            \(exists ? "Changed" : "Created") \(workflowID). \(parsed.summary). \
            It is live now; it shows on the project page, where they can run or pause it.
            """
    }

    private func removeWorkflowForAgent(_ workflowID: String?, in project: URL,
                                        agentID: UUID) async throws -> String {
        let url = try workflowURL(workflowID, in: project)
        guard let workflow = workflow(url.deletingPathExtension().lastPathComponent, in: project) else {
            throw JSONRPCError(code: DaemonAPI.Failure.noSuchWorkflow,
                               message: "There is no workflow called \(workflowID ?? "") in this project.")
        }
        let allowed = try await askAboutWorkflow(
            DaemonAPI.WorkflowConfirmation(
                agentID: agentID, folder: project, workflowID: workflow.workflowID,
                action: .remove, summary: workflow.summary, prompt: workflow.prompt))
        guard allowed else {
            throw JSONRPCError(code: DaemonAPI.Failure.notConfirmed,
                               message: "They declined, so nothing was removed.")
        }
        try FileManager.default.removeItem(at: url)
        rescanWorkflows(in: project)
        return "\(workflow.workflowID) is gone. It will not run again."
    }

    // MARK: The question

    /// Put a write to the person and wait.
    ///
    /// Held on the actor for the same reason a permission or a form is: the question can
    /// arrive while no window is open, and the agent is owed an answer either way.
    /// Deliberately not a `PermissionRequest` — that is a thing a runtime asked and is
    /// answered back into an ACP session, whereas this begins here and is answered by
    /// doing or not doing a file write.
    private func askAboutWorkflow(_ confirmation: DaemonAPI.WorkflowConfirmation) async throws -> Bool {
        guard connectionCount > 0 else {
            // Told, not swallowed, the way `showFile` is. An agent working for somebody
            // who closed the window an hour ago deserves to know why nothing happened.
            throw JSONRPCError(code: DaemonAPI.Failure.noSuchAgent,
                               message: "No window is open, so there was nobody to ask. Nothing was written.")
        }

        let timeout = Task { [weak self] in
            try? await Task.sleep(for: DaemonCore.workflowConfirmationTimeout)
            guard !Task.isCancelled else { return }
            await self?.answerWorkflowConfirmation(
                DaemonAPI.WorkflowConfirmRequest(confirmationID: confirmation.id, allow: false))
        }
        defer { timeout.cancel() }

        let allowed = await withCheckedContinuation { continuation in
            workflowConfirmations[confirmation.id] =
                PendingWorkflowConfirmation(confirmation: confirmation, answer: continuation)
            broadcast(DaemonAPI.Notification.workflowConfirmation,
                      DaemonAPI.WorkflowConfirmationNotification(confirmation: confirmation))
        }
        return allowed
    }

    /// The person answered, or nobody did.
    public func answerWorkflowConfirmation(_ request: DaemonAPI.WorkflowConfirmRequest) {
        guard let pending = workflowConfirmations.removeValue(forKey: request.confirmationID) else { return }
        broadcast(DaemonAPI.Notification.workflowConfirmation,
                  DaemonAPI.WorkflowConfirmationNotification(confirmation: nil))
        pending.answer.resume(returning: request.allow)
    }

    public func pendingWorkflowConfirmations() -> [DaemonAPI.WorkflowConfirmation] {
        workflowConfirmations.values.map(\.confirmation).sorted { $0.askedAt < $1.askedAt }
    }

    // MARK: The boundary

    /// Where a workflow of this project's would live, refusing anything that is not one.
    ///
    /// Two checks rather than one, because a name is not a path until it has been
    /// resolved: `isValidID` rejects the obvious — a slash, a `..`, a dotfile — and the
    /// containment check rejects whatever is left after symlinks have had their say.
    private func workflowURL(_ workflowID: String?, in project: URL) throws -> URL {
        guard let workflowID, WorkflowFolder.isValidID(workflowID) else {
            throw JSONRPCError(code: DaemonAPI.Failure.notInWorkflowFolder,
                               message: """
                                Workflows can only be read and written inside this \
                                project's \(WorkflowFile.folderName), and \
                                \(workflowID ?? "that") is not a name in it.
                                """)
        }
        let url = WorkflowFile.url(for: workflowID, in: project)
        guard WorkflowFolder.contains(url, project: project) else {
            throw JSONRPCError(code: DaemonAPI.Failure.notInWorkflowFolder,
                               message: """
                                Workflows can only be read and written inside this \
                                project's \(WorkflowFile.folderName).
                                """)
        }
        return url
    }
}
