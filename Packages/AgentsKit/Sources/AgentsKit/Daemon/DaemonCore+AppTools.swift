import Foundation

/// Where an agent's account of its turn, a file it wants looked at, and its say over
/// the project's workflows come from.
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
    ///
    /// The older door for the chips half of `finishTurn` (023). It stays because the
    /// helper relays the older tool name here, and a conversation briefed with that
    /// name is still calling it. It touches the chips and nothing else.
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
        return Self.shownNote(count: prompts.count)
    }

    /// An agent has said how the work actually went.
    ///
    /// The last thing it does, and the only thing that can tell a turn being handed
    /// back from the work being finished. Everything refused here is refused in a
    /// sentence rather than a code, because the agent is what reads it.
    ///
    /// Since 023 this is the older of two doors to the same record. `finishTurn` is
    /// the one a fresh conversation is told about; this stays because the helper
    /// relays the older name to it, and a conversation briefed with that name is still
    /// calling it. Both go through `checkedReport` and `land`, so the refusals and the
    /// order of the writes cannot drift between them.
    public func reportOutcome(_ request: DaemonAPI.ReportOutcomeRequest) async throws -> String {
        let checked = try checkedReport(token: request.token, outcome: request.outcome,
                                        message: request.message)
        return await land(checked.report, prompts: nil, on: checked.agent, id: checked.agentID)
    }

    /// The one call that ends a turn: how it went, and what to ask next (023).
    ///
    /// The merge is here and not in the helper because a call is refused whole or
    /// lands whole. Two relayed calls could show the chips and then refuse the outcome
    /// for a form still waiting, which is exactly the picture — suggestions beneath an
    /// ending nobody accounted for — this tool exists to remove. So every check runs
    /// before either write, and the two writes go out in one `changed`.
    ///
    /// No prompts is an empty row, not "leave them": the last call is the whole
    /// account of the turn, chips included, so a call without any clears whatever an
    /// earlier call in the same turn left.
    public func finishTurn(_ request: DaemonAPI.FinishTurnRequest) async throws -> String {
        let checked = try checkedReport(token: request.token, outcome: request.outcome,
                                        message: request.message)
        let prompts = Array(request.prompts.prefix(SuggestedPrompt.limit))
        // Cleaned again here, not trusted from the helper: the daemon is what writes
        // the record, and a helper from an older binary sends no title at all — which
        // leaves the name as it was rather than refusing a call the agent was never
        // told needed one.
        let title = request.title.flatMap(Agent.cleanedTitle)
        let noted = await land(checked.report, prompts: prompts, title: title,
                               on: checked.agent, id: checked.agentID)
        return prompts.isEmpty ? noted : noted + " " + Self.shownNote(count: prompts.count)
    }

    /// The refusals a report can meet, in the order it meets them, each a sentence the
    /// agent reads: a token that no longer speaks for an agent, a word that is not one
    /// of the five, a question of the agent's own still outstanding, and no words.
    ///
    /// The one worth the words is the third. Claiming the work is settled while the
    /// app is holding a form or a permission for the person would tell them the
    /// opposite of the truth, so the agent is sent back to its own question first.
    private func checkedReport(token: String, outcome rawOutcome: String, message: String)
        throws -> (agentID: UUID, agent: Agent, report: WorkReport) {
        guard let agentID = appTokens[token], let agent = agents[agentID] else {
            throw JSONRPCError(code: DaemonAPI.Failure.noSuchAgent,
                               message: "That conversation is not open any more, so nothing was recorded.")
        }
        guard let outcome = WorkOutcome(wire: rawOutcome) else {
            // Never rounded to the nearest one we know. An unrecognised word read as
            // `done` is the unearned tick this whole feature exists to remove.
            throw JSONRPCError(code: JSONRPCError.invalidParams,
                               message: """
                                Nothing was recorded: outcome has to be one of done, \
                                nothing_to_do, needs_answer, partly_done or stuck.
                                """)
        }
        let waiting = pendingPermissions.values.contains { $0.agentID == agentID }
            || elicitations.values.contains { $0.agentID == agentID }
        guard !waiting else {
            throw JSONRPCError(code: JSONRPCError.invalidParams,
                               message: """
                                Nothing was recorded: you have a question waiting to be \
                                answered, so this work is not over. Answer it first, or \
                                let it be answered.
                                """)
        }
        guard let report = WorkReport(outcome: outcome, wire: message) else {
            throw JSONRPCError(code: JSONRPCError.invalidParams,
                               message: """
                                Nothing was recorded: say in a sentence how it went. An \
                                outcome with no words is no more use than the turn simply \
                                ending.
                                """)
        }
        return (agentID, agent, report)
    }

    /// Put a report on the agent — and a row of chips, where the call carried one —
    /// and say what became of it.
    private func land(_ report: WorkReport, prompts: [SuggestedPrompt]?, title: String? = nil,
                      on agent: Agent, id agentID: UUID) async -> String {
        var agent = agent
        // Replacing whatever this turn said before it changed its mind (FR-005).
        agent.report = report
        if let prompts { agent.suggestedPrompts = prompts }
        // Said in front of the person, so already seen: no banner for what they watched.
        if isWatched(agentID) { agent.reportSeenAt = report.at }
        // In the same write as the report, so no window ever sees the new account of
        // the work under the old name for it.
        if let title {
            agent.title = title
            agent.titledByAgent = true
        }
        // The record before the windows, which is the order that leaves something true
        // behind when the daemon is killed mid-call.
        await record(.workReported(report), for: agentID)
        changed(agent)
        // A report that says the agent is stuck begins a need without a state change,
        // which is why this is the one place besides `move` that has to ask (021).
        reconsider()
        return report.outcome.needsAPerson
            ? """
                Noted. The person will see this conversation under "Needs attention", \
                with your message on it.
                """
            : "Noted. This conversation now reads as \"\(report.outcome.heading)\" wherever the person looks."
    }

    /// What an agent is told about its chips, by either door.
    static func shownNote(count: Int) -> String {
        count == 1
            ? "Shown above the prompt. The person may tap it, edit it, or ignore it."
            : "\(count) shown above the prompt. The person may tap one, edit it, or ignore them."
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
        let exists = FileManager.default.fileExists(atPath: request.file.path, isDirectory: &isDirectory)
        // A Markdown file is a page that fills as it is written (022), so an agent
        // may show it before its first write — that is exactly when it should. The
        // folder it will go in has to be there, or the agent is naming a place it
        // cannot write to either. Anything else still has to exist: a source file
        // that is not there is a mistake, not a page about to begin.
        if !exists {
            let folder = request.file.url.deletingLastPathComponent().path
            var folderIsDirectory: ObjCBool = false
            guard request.file.isMarkdown,
                  FileManager.default.fileExists(atPath: folder, isDirectory: &folderIsDirectory),
                  folderIsDirectory.boolValue else {
                throw JSONRPCError(code: JSONRPCError.invalidParams,
                                   message: "There is no file at \(request.file.path).")
            }
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
        guard exists else {
            return """
                \(request.file.name) is open, empty, in the files pane beside this \
                conversation, and will fill as you write it. Just write; do not paste \
                the file back.
                """
        }
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

    /// Answer the permission question for the app's own tools ourselves.
    ///
    /// Copilot asks before every tool call, including these. A sheet asking whether
    /// the app may show the app's own suggestions is a question with no information in
    /// it, and asked once a turn it would be worse than not having the feature. The
    /// same goes for opening a file in a read-only pane, in a folder the agent can
    /// already read, in the window the person is looking at.
    ///
    /// The workflow tool is here too, which it was not at first. A question in front
    /// of the writing was answerable only by somebody willing to read a prompt they
    /// had not asked to see, and under a runtime that asks before every call it was
    /// also the thing that stopped an agent dead whenever nobody was looking. The
    /// answer is after the fact instead: a workflow is written, appears on the project
    /// page, and can be archived there by somebody who can see what it does.
    /// Allowed only where the runtime offered allowing it, and only for the app's
    /// own tools — the one that ends a turn, the two that act mid-turn, and the two
    /// older names.
    func autoAllowed(_ request: PermissionRequest) -> PermissionOption? {
        guard request.toolCall.isAutoAllowable else { return nil }
        return request.options.first { $0.kind == .allowAlways }
            ?? request.options.first { $0.kind == .allowOnce }
    }

    /// And refuse, ourselves, the ones this app could not take away.
    ///
    /// Three of the four runtimes let the app remove its rivals outright, and what is
    /// removed needs no answer: the model never sees it. This is for the remainder —
    /// the tools a runtime holds on to — and it fires only where that runtime asks the
    /// client before running one.
    ///
    /// The sentence comes from the tool's remit category, which is the same place the
    /// briefing's residue line reads, so the two cannot end up saying different things
    /// about the same tool. It names what to use instead rather than reporting that
    /// something was blocked: an agent can act on the first and not on the second.
    ///
    /// Nothing is refused where the runtime offered no way of refusing. Answering with
    /// an option it did not give would be worse than letting the call through.
    func autoRefused(_ request: PermissionRequest) -> (option: PermissionOption, note: String)? {
        guard let runtimeID = agents[request.agentID]?.runtimeID else { return nil }
        let policy = ToolPolicyCatalog.policy(for: runtimeID)
        guard let residual = policy.residual(matching: request.toolCall.name ?? request.toolCall.title),
              let option = request.options.first(where: { $0.kind == .rejectOnce })
                  ?? request.options.first(where: { $0.kind == .rejectAlways })
        else { return nil }
        return (option, "`\(residual.name)` is not available in this app. \(residual.instead)")
    }
}

/// The workflow tool: what an agent may do to its own project's standing arrangements.
///
/// Nothing here asks first. An agent told to set up a workflow sets one up, and the
/// person's say is on the project page afterwards, where a workflow can be archived by
/// somebody looking at what it actually does. Asking first was tried and
/// was worse in both directions: it put a prompt nobody had asked to read in front of
/// a decision, and it left the agent blocked whenever there was no window to read it.
extension DaemonCore {
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
            return try writeWorkflowForAgent(request, in: project)
        case .remove:
            return try removeWorkflowForAgent(request.workflowID, in: project)
        }
    }

    // MARK: Reading

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
            if summary.isArchived { line += " [archived]" }
            if summary.overLimit != nil { line += " [over the limit, so it will not run]" }
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

    // MARK: Writing

    private func writeWorkflowForAgent(_ request: DaemonAPI.ManageWorkflowsRequest,
                                       in project: URL) throws -> String {
        let url = try workflowURL(request.workflowID, in: project)
        guard let content = request.content, !content.isEmpty else {
            throw JSONRPCError(code: JSONRPCError.invalidParams,
                               message: "Nothing was written: `content` has to be the whole file.")
        }

        // Parsed before anything is written. A file that could never fire is worth
        // saying so about while the agent is still there to fix it, and it keeps a row
        // nobody can act on off the project page.
        let workflowID = url.deletingPathExtension().lastPathComponent
        let parsed = WorkflowFile.parse(content, workflowID: workflowID, in: project)
        if case .unreadable(let why) = parsed.problem {
            throw JSONRPCError(code: DaemonAPI.Failure.workflowUnreadable,
                               message: "That front matter could not be read: \(why). Nothing was written.")
        }

        // A new one, in a project already holding as many as it may. Refused here
        // rather than written and left inert, because an agent that is told now can
        // offer to change one of the three instead — and because a file written to no
        // effect is the kind of thing nobody finds until it matters.
        let exists = FileManager.default.fileExists(atPath: url.path)
        if !exists {
            adoptWorkflows(in: project)
            let records = workflowStore.load()
            if liveWorkflowCount(in: project, records: records) >= WorkflowLimit.project.allowed {
                let names = liveWorkflowIDs(in: project, records: records).joined(separator: ", ")
                throw JSONRPCError(code: DaemonAPI.Failure.workflowLimitReached,
                                   message: """
                                    Nothing was written: a project may run \
                                    \(WorkflowLimit.project.allowed) workflows and this one \
                                    already has \(names). Change one of those instead, or ask \
                                    them to archive one to make room.
                                    """)
            }
            if liveWorkflowCount(records: records) >= WorkflowLimit.total.allowed {
                throw JSONRPCError(code: DaemonAPI.Failure.workflowLimitReached,
                                   message: """
                                    Nothing was written: \(WorkflowLimit.total.allowed) \
                                    workflows are already running across their projects, which \
                                    is as many as this app runs at once. Ask them to archive \
                                    one — anywhere — to make room.
                                    """)
            }
        }
        try FileManager.default.createDirectory(at: WorkflowFile.folder(in: project),
                                                withIntermediateDirectories: true)
        // Written whole, exactly as it was handed over. Nothing is re-serialised from
        // the parsed form, which is what makes a key this version does not know survive
        // being written by an agent running against a later one.
        try Data(content.utf8).write(to: url, options: .atomic)
        // An archived id written to again stays archived. The one thing the person can
        // say about a workflow they did not ask for should not be undone by the agent
        // that wrote it.
        let archived = workflowStore.load()
            .state(folder: project, workflowID: workflowID)?.isArchived ?? false
        rescanWorkflows(in: project)
        if archived {
            return """
                \(exists ? "Changed" : "Created") \(workflowID). \(parsed.summary). \
                It is archived, though, so it will not run until they bring it back \
                from the project page. Tell them it is there.
                """
        }
        return """
            \(exists ? "Changed" : "Created") \(workflowID). \(parsed.summary). \
            It is live now; it shows on the project page, where they can run it, pause \
            it, or archive it if it is not what they wanted.
            """
    }

    private func removeWorkflowForAgent(_ workflowID: String?, in project: URL) throws -> String {
        let url = try workflowURL(workflowID, in: project)
        guard let workflow = workflow(url.deletingPathExtension().lastPathComponent, in: project) else {
            throw JSONRPCError(code: DaemonAPI.Failure.noSuchWorkflow,
                               message: "There is no workflow called \(workflowID ?? "") in this project.")
        }
        try FileManager.default.removeItem(at: url)
        rescanWorkflows(in: project)
        return "\(workflow.workflowID) is gone. It will not run again."
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
