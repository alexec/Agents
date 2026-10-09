import Foundation

/// Where an agent's account of its turn, a file it wants looked at, and its say over
/// the project's workflows come from.
///
/// The app hands every session an MCP server of its own. The daemon serves it itself,
/// over loopback http (`AppToolsEndpoint`, #185): the runtime is given an address and a
/// bearer, and every tool call arrives here as the method behind it, which is why the
/// whole of the decision-making is here and testable.
///
/// The token is what makes the call belong to an agent. It is minted per session,
/// bound when the agent exists, and dropped when the session ends, at which point the
/// endpoint refuses it too, so a runtime left behind cannot post into a conversation it
/// is no longer part of. It is a bearer header on a loopback request, handed to the
/// runtime in `session/new`, and never in any process's environment (security review S7).
extension DaemonCore {
    /// The MCP server every agent is given, beside whatever the user attached.
    ///
    /// An agent another agent started is not offered the tools for starting, stopping
    /// and archiving agents (028), so it is never offered what the daemon would refuse it.
    ///
    /// And an agent on a runtime that cannot carry its conversation into another folder is
    /// not offered the tools for moving itself (053).
    func appServer(token: String, managesAgents: Bool = true, movesItself: Bool = true) async throws -> MCPServer {
        let port = try await appTools.start()
        appTools.grant(token, .init(managesAgents: managesAgents, movesItself: movesItself))
        return AppToolsEndpoint.server(port: port, token: token)
    }

    /// One of the app's tools, from the endpoint. As the helper's socket connection was: an
    /// agent's, so nothing it asks for is taken as the person's, and nothing outside the
    /// app's tools is answered.
    func appToolCall(method: String, params: JSONValue) async -> Result<JSONValue, JSONRPCError> {
        guard ConnectionRole.agent.allows(method) else {
            return .failure(JSONRPCError(code: JSONRPCError.methodNotFound, message: "Not one of the app's tools."))
        }
        return await handle(method: method, params: params, role: .agent)
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
            endAppTools(for: existing)
        }
        appTokens[token] = agentID
    }

    /// A token stops speaking for anyone: the endpoint refuses it and the bridge's routes
    /// for it end.
    func endAppTools(for token: String) {
        appTools.revoke(token)
        endBridgeRoutes(for: token)
    }

    func dropAppTokens(for agentID: UUID) {
        for (token, id) in appTokens where id == agentID {
            appTokens.removeValue(forKey: token)
            endAppTools(for: token)
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
        return Self.shownNote
    }

    /// An agent has said how the work actually went.
    ///
    /// The last thing it does, and the only thing that can tell a turn being handed
    /// back from the work being finished. Everything refused here is refused in a
    /// sentence rather than a code, because the agent is what reads it.
    ///
    /// Since 023 this is the older of two doors to the same record. `finishTurn` is
    /// the one a fresh conversation is told about. The helper stopped relaying the
    /// older name on 09-29; this stays for a helper from before then, which is after
    /// the #58 cut-off (051). Both go through `checkedReport` and `land`, so the refusals and the
    /// order of the writes cannot drift between them.
    public func reportOutcome(_ request: DaemonAPI.ReportOutcomeRequest) async throws -> String {
        let checked = try checkedReport(token: request.token, outcome: request.outcome,
                                        message: request.message, waitingOn: request.waitingOn,
                                        checkAgainInMinutes: request.checkAgainInMinutes)
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
                                        message: request.message, waitingOn: request.waitingOn,
                                        checkAgainInMinutes: request.checkAgainInMinutes,
                                        wakeOn: request.wakeOn)
        // Checked after the report's own refusals, so an agent that got the outcome
        // wrong hears about that first; and before either write, so a refused ask
        // leaves nothing behind (the whole call is refused).
        var afterwards: AfterTurn?
        if let written = request.afterwards {
            guard let after = AfterTurn(wire: written) else {
                throw JSONRPCError(code: JSONRPCError.invalidParams, message: AfterTurn.unknown)
            }
            guard after.goes(with: checked.report.outcome) else {
                throw JSONRPCError(code: JSONRPCError.invalidParams, message: after.refusal)
            }
            // Only a workflow's run, and only when its author allowed it (#433).
            if after == .archive, whenDone(forRunOf: checked.agentID)?.allowsArchiveAsk != true {
                throw JSONRPCError(code: JSONRPCError.invalidParams, message: AfterTurn.archiveNotAllowed)
            }
            afterwards = after
        }
        // A move is the agent carrying on somewhere else, so it does not go with an
        // ending that waits for someone (053), or with being archived. With a park it
        // does since #481: the agent moves, and stays parked there.
        if request.move != nil {
            let waits = [WorkOutcome.needsAnswer, .blocked].contains(checked.report.outcome)
            guard !waits, afterwards != .archive else {
                throw JSONRPCError(code: JSONRPCError.invalidParams, message: Self.moveRefusal)
            }
        }
        let prompts = Array(request.prompts.prefix(SuggestedPrompt.limit))
        // Cleaned again here, not trusted from the helper: the daemon is what writes
        // the record. No title — the goal has not changed, or a helper from an older
        // binary sent none — leaves the name as it was.
        let title = request.title.flatMap(Agent.cleanedTitle)
        let labels: [SessionLabel]
        do {
            labels = try SessionLabelPolicy.change(
                current: checked.agent.labels, add: request.addLabels,
                remove: request.removeLabels, actor: .agent,
                projectLabels: SessionLabelPolicy.vocabulary(
                    in: checked.agent.projectFolder, agents: agents.inProject(checked.agent.projectFolder)))
        } catch {
            throw JSONRPCError(code: JSONRPCError.invalidParams,
                               message: "Nothing was recorded: \(error.localizedDescription)")
        }
        // Last of the checks, since it is the one that writes: a move refused here (a
        // name it cannot use, a removal that would lose work) refuses the whole call,
        // and one accepted is kept on the agent for when the turn ends.
        var moved: String?
        if let move = request.move {
            moved = try await askMove(checked.agentID,
                                      PendingMove(target: move.target, removeLeft: move.removeLeft,
                                                  discardChanges: move.discardChanges,
                                                  askedBy: .agent, askedAt: now())).message
        } else if agents[checked.agentID]?.pendingMove?.askedBy == .agent {
            // The last call is the whole account of the turn, so one without a move
            // takes back the move an earlier call asked for. The person's stays.
            agents[checked.agentID]?.pendingMove = nil
            await record(.runtimeNote("Move cancelled."), for: checked.agentID)
        }
        let noted = await land(checked.report, prompts: prompts, title: title,
                               afterwards: afterwards,
                               labels: labels,
                               on: agents[checked.agentID] ?? checked.agent, id: checked.agentID)
        // A run its workflow archives when done is told so whatever it asked (#433).
        let archivedAnyway = whenDone(forRunOf: checked.agentID) == .archive
            && AfterTurn.archive.goes(with: checked.report.outcome) && request.move == nil
        let asked = archivedAnyway ? " " + Self.afterTurnNote(.archive)
            : afterwards.map { " " + Self.afterTurnNote($0) } ?? ""
        let moving = moved.map { " " + $0 } ?? ""
        return (prompts.isEmpty ? noted : noted + " " + Self.shownNote) + asked + moving
    }

    static let moveRefusal = """
        Nothing was recorded: a move carries you on in the new folder, so it does not go \
        with needs_answer, blocked or being archived. End the turn without worktree or \
        leave_worktree, or with done, nothing_to_do, partly_done or stuck.
        """

    /// The refusals a report can meet, in the order it meets them, each a sentence the
    /// agent reads: a token that no longer speaks for an agent, a word that is not one
    /// of the five, a question of the agent's own still outstanding, too many words,
    /// and no words.
    ///
    /// The one worth the words is the third. Claiming the work is settled while the
    /// app is holding a form or a permission for the person would tell them the
    /// opposite of the truth, so the agent is sent back to its own question first.
    private func checkedReport(token: String, outcome rawOutcome: String, message: String,
                               waitingOn: [String]? = nil, checkAgainInMinutes: Int? = nil,
                               wakeOn rawWakeOn: String? = nil)
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
                                nothing_to_do, needs_answer, partly_done, stuck or blocked.
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
        // Refused, not cut (#184): nothing is recorded, so the turn is still the
        // agent's to account for, and the same call with fewer words lands.
        guard !WorkReport.isTooLong(message) else {
            throw JSONRPCError(code: JSONRPCError.invalidParams, message: WorkReport.tooLong(outcome))
        }
        guard var report = WorkReport(outcome: outcome, wire: message) else {
            throw JSONRPCError(code: JSONRPCError.invalidParams,
                               message: """
                                Nothing was recorded: say in a sentence how it went. An \
                                outcome with no words is no more use than the turn simply \
                                ending.
                                """)
        }
        // Last, because it is the only check that reads other agents (039): everything
        // about this call alone has passed by now.
        var wakeOn: Block.WakeOn?
        if let rawWakeOn {
            guard let known = Block.WakeOn(rawValue: rawWakeOn) else {
                throw JSONRPCError(code: JSONRPCError.invalidParams, message: Block.unknownWakeOn)
            }
            wakeOn = known
        }
        if outcome == .blocked {
            report.block = try checkedBlock(for: agent, waitingOn: waitingOn ?? [],
                                            checkAgainInMinutes: checkAgainInMinutes,
                                            wakeOn: wakeOn, at: report.at)
        } else if waitingOn?.isEmpty == false || checkAgainInMinutes != nil || wakeOn != nil {
            throw JSONRPCError(code: JSONRPCError.invalidParams, message: Block.onlyWithBlocked)
        }
        return (agentID, agent, report)
    }

    /// Put a report on the agent — and a row of chips, where the call carried one —
    /// and say what became of it.
    ///
    /// `afterwards`, when the call carries one, replaces the ask. A call without one keeps
    /// an ask `park_agent` made (#481) — unless this ending does not go with it: an ask
    /// left under a later `stuck` would put away work that needs somebody, so it is
    /// dropped, and the agent told.
    private func land(_ report: WorkReport, prompts: [SuggestedPrompt]?, title: String? = nil,
                      afterwards: AfterTurn? = nil,
                      labels: [SessionLabel]? = nil,
                      on agent: Agent, id agentID: UUID) async -> String {
        var agent = agent
        // Replacing whatever this turn said before it changed its mind (FR-005).
        agent.report = report
        if let prompts { agent.suggestedPrompts = prompts }
        var dropped: AfterTurn?
        if let afterwards {
            agent.afterTurn = afterwards
        } else if let asked = agent.afterTurn, !asked.goes(with: report.outcome) {
            agent.afterTurn = nil
            dropped = asked
        }
        let droppedNote = dropped.map {
            " Your ask to be \($0 == .park ? "parked" : "archived") is dropped: it does not go with \(report.outcome.rawValue)."
        } ?? ""
        if let labels { agent.labels = labels }
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
        // The turn is over when the agent says so, whether or not its runtime lets go
        // of the prompt (#139).
        watchTheEnd(of: agentID)
        // A report that says the agent is stuck begins a need without a state change,
        // which is why this is the one place besides `move` that has to ask (021).
        reconsider()
        if report.outcome == .blocked {
            // On the log, as a wait on events is (042).
            let waitingOn = report.block.map { block in
                block.waits.map { "\u{201C}\(self.waitName($0))\u{201D}" }.joined(separator: ", ")
            } ?? ""
            let anyOf = report.block?.wakeOn == .any && (report.block?.waits.count ?? 0) > 1
            raiseAgentEvent("agent.blocked", agentID,
                            sentence: waitingOn.isEmpty ? "is blocked."
                                : "is waiting for \(anyOf ? "any of " : "")\(waitingOn) to finish.",
                            details: waitingOn.isEmpty ? [:] : ["waiting_on": waitingOn])
            // Reported after its turn had already ended, with everything it named
            // already over by then: nothing else will pass through `move` for it.
            await resumeIfCleared(agentID)
            return Self.blockedNote(report.block, names: { self.waitName($0) }) + droppedNote
        }
        return report.outcome.needsAPerson
            ? """
                Noted. The person will see this conversation under "Needs attention", \
                with your message on it.
                """ + droppedNote
            : "Noted. This conversation now reads as \"\(report.outcome.heading)\" wherever the person looks." + droppedNote
    }

    /// What an agent is told about its suggestion, by either door. There is only
    /// ever one to tell it about (031), whatever it sent.
    static let shownNote = "Shown in the person's empty prompt. They may take it, edit it, or ignore it."

    /// What an agent is told about its ask to be put away. "Once this turn ends",
    /// because nothing happens yet, and the person can still move the work on.
    static func afterTurnNote(_ after: AfterTurn) -> String {
        switch after {
        case .park: return "Once this turn ends, this conversation will be parked."
        case .archive: return "Once this turn ends, this conversation will be archived, as its workflow allows."
        }
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

    /// An agent has asked the person a question via `ask_form`, and is waiting.
    ///
    /// The form is held as an ordinary elicitation so the phone and every window can
    /// answer it the same way they answer a runtime's own question. The call parks
    /// until that answer arrives, the person skips or cancels, or the agent stops.
    public func askForm(_ request: DaemonAPI.AskFormRequest) async throws -> String {
        guard let agentID = appTokens[request.token], agents[agentID] != nil else {
            throw JSONRPCError(code: DaemonAPI.Failure.noSuchAgent,
                               message: "That conversation is not open any more, so nobody was asked.")
        }
        guard turnTasks[agentID] != nil else {
            throw JSONRPCError(code: JSONRPCError.invalidRequest,
                               message: "A question can only be asked while this agent is working.")
        }
        guard !request.questions.isEmpty else {
            throw JSONRPCError(code: JSONRPCError.invalidParams,
                               message: "Nothing was asked: send at least one question.")
        }
        var properties: [ElicitationSchema.Property] = []
        for question in request.questions {
            let id = question.id.trimmingCharacters(in: .whitespacesAndNewlines)
            let prompt = question.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, !prompt.isEmpty else {
                throw JSONRPCError(code: JSONRPCError.invalidParams,
                                   message: "Nothing was asked: each question needs an id and a prompt.")
            }
            let choices = (question.options ?? []).compactMap { option -> ElicitationSchema.Property.Choice? in
                let value = option.id.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty else { return nil }
                return .init(value: value, title: option.label)
            }
            let kind: ElicitationSchema.Property.Kind
            if choices.isEmpty {
                kind = .string(format: nil, minLength: nil, maxLength: nil, choices: nil)
            } else if question.allowMultiple == true {
                kind = .multiSelect(items: choices, minItems: nil, maxItems: nil)
            } else {
                kind = .string(format: nil, minLength: nil, maxLength: nil, choices: choices)
            }
            properties.append(.init(name: id, title: prompt, isRequired: true, kind: kind))
        }
        let title = request.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedTitle = (title?.isEmpty == false) ? title : nil
        let elicitation = ElicitationRequest(
            agentID: agentID,
            message: cleanedTitle ?? (properties.count == 1 ? properties[0].title : nil),
            mode: .form(ElicitationSchema(title: cleanedTitle, properties: properties)))
        // Parked before anything is awaited, so an answer arriving in the next
        // instant finds the call to resume rather than starting the agent again.
        let answer = await withCheckedContinuation { (continuation: CheckedContinuation<Result<String, JSONRPCError>, Never>) in
            openAsks[elicitation.id] = continuation
            Task { await self.holdElicitation(elicitation, agentID: agentID) }
        }
        switch answer {
        case .success(let text): return text
        case .failure(let error): throw error
        }
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

    /// Cursor and Grok (061): only the tools that end or annotate a turn, never the ones
    /// that start agents, change workflows, take leases or publish.
    func autoAllowedTurnTool(_ request: PermissionRequest) -> PermissionOption? {
        let call = request.toolCall
        guard call.isFinishingTurn || call.isOwnSessionCall || call.isShowingFile else { return nil }
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
/// person's say is on the project page afterwards: what an agent writes waits there for
/// their Approve before it ever runs (security review), and can be archived by somebody
/// looking at what it actually does. Asking in the middle of the call was tried and
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
        let project = agent.projectFolder

        switch request.action {
        case .list:
            return listWorkflowsForAgent(in: project)
        case .read:
            return try readWorkflowForAgent(request.workflowID, in: project)
        case .write:
            return try writeWorkflowForAgent(request, in: project)
        case .remove:
            return try removeWorkflowForAgent(request.workflowID, in: project)
        case .enable, .disable:
            return try enableWorkflowForAgent(request.workflowID, enabled: request.action == .enable,
                                              in: project)
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
            switch summary.offReason {
            case .file: line += " [turned off: its file says enabled: false]"
            case .writtenByAgent: line += " [turned off: written by an agent, waiting for the person]"
            case .agent: line += " [turned off by an agent]"
            case .person, nil: if !summary.isEnabled { line += " [turned off]" }
            }
            if summary.overLimit != nil { line += " [over the limit, so it will not run]" }
            if let never = neverHere(summary.workflow) { line += " [\(never)]" }
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
        let parsed = WorkflowFile.parse(text, workflowID: url.deletingPathExtension().lastPathComponent,
                                        in: project)
        guard let menu = offeredSettings(for: parsed) else { return text }
        // Set apart from the file, so an agent copying the text back does not write
        // this into it.
        return text + "\n\n(End of the file. Not part of it:)\n" + menu
    }

    /// What the workflow's runtime last offered in this project, as the keys a file
    /// writes it with — so an agent changing a workflow's settings can see the words
    /// that will work, rather than guessing at `plan` on a runtime that calls it
    /// something else.
    ///
    /// From the daemon's memory, and said to be: nothing is started to ask, and a
    /// runtime can change its menu. The fire is still what checks.
    private func offeredSettings(for workflow: Workflow) -> String? {
        let runtimeID = workflow.settings.runtimeID ?? RuntimeCatalog.defaultRuntime.id
        let name = RuntimeCatalog.runtime(id: runtimeID)?.name ?? runtimeID
        let advertised = rememberedOptions(DaemonAPI.RememberedOptionsRequest(runtimeID: runtimeID,
                                                                              cwd: workflow.folder))
        // Nothing remembered is nothing to add: the file is the whole answer, and the
        // fire still checks whatever it names.
        guard !advertised.isEmpty else { return nil }
        func line(_ key: String, _ option: ConfigOption?) -> String? {
            guard let option else { return nil }
            return "- `\(key):` \(WorkflowSettings.offered(by: option).joined(separator: ", "))"
        }
        var lines = [
            line(WorkflowSettings.Setting.permissionMode, ModeMemory.modeOption(in: advertised)),
            line(WorkflowSettings.Setting.model, WorkflowSettings.modelOption(in: advertised)),
            line(WorkflowSettings.Setting.effort, WorkflowSettings.effortOption(in: advertised)),
        ].compactMap { $0 }
        let others = advertised.filter {
            $0.isRenderable && !WorkflowSettings.isNamedOnItsOwn($0, in: advertised)
        }
        if !others.isEmpty {
            lines.append("- under `\(WorkflowSettings.Setting.options):`")
            lines += others.map {
                "  - `\($0.id):` \(WorkflowSettings.offered(by: $0).joined(separator: ", "))"
                    + " (\($0.name))"
            }
        }
        return (["What \(name) last offered in this project, as a file writes it:"] + lines)
            .joined(separator: "\n")
    }

    /// Values the runtime is remembered not to offer, said while the agent that wrote
    /// them is still there to fix them. Not a refusal: the memory can be stale, and the
    /// fire is what decides.
    private func unofferedWarning(for workflow: Workflow) -> String? {
        let runtimeID = workflow.settings.runtimeID ?? RuntimeCatalog.defaultRuntime.id
        guard !workflow.settings.isEmpty, RuntimeCatalog.runtime(id: runtimeID) != nil else { return nil }
        let advertised = rememberedOptions(DaemonAPI.RememberedOptionsRequest(runtimeID: runtimeID,
                                                                              cwd: workflow.folder))
        guard !advertised.isEmpty,
              case .refused(let setting, let value, let offered) = WorkflowSettings.resolve(
                workflow.settings, against: advertised)
        else { return nil }
        let name = RuntimeCatalog.runtime(id: runtimeID)?.name ?? runtimeID
        let detail = WorkflowSettings.refusalDetail(setting: setting, value: value,
                                                    offered: offered, runtime: name)
        return "But \(detail), so as it stands it will not run. Fix it with another write."
    }

    /// The triggers in it only a Mac raises, said on a Linux host, where they never
    /// fire (#372). Not a refusal: the file may travel to a Mac.
    private func neverHere(_ workflow: Workflow) -> String? {
        guard !raisesMacOnlyEvents else { return nil }
        let names = workflow.triggers.flatMap(\.patterns).map(\.name).filter(EventCatalogue.isMacOnly)
        return names.isEmpty ? nil : EventWords.neverHere(names)
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

        // Whatever an agent writes waits for the person's OK, so a fourth waiting one in
        // this project is refused here rather than written and left inert (#132): an
        // agent told now can offer to change one of the three instead, and a file
        // written to no effect is the kind of thing nobody finds until it matters. One
        // already waiting is not a new place, and an archived one takes none.
        let exists = FileManager.default.fileExists(atPath: url.path)
        adoptWorkflows(in: project)
        let before = workflowStore.load()
        let ceilings = workflowCeilings(records: before)
        let existingText = exists ? try? String(contentsOf: url, encoding: .utf8) : nil
        let existing = existingText.map { WorkflowFile.parse($0, workflowID: workflowID, in: project) }
        let isArchived = existing?.isArchived ?? false
        let waiting = ceilings.waiting[Project.standardize(project)] ?? []
        if !isArchived, !waiting.contains(workflowID), waiting.count >= WorkflowLimit.project.allowed {
            let names = waiting.prefix(WorkflowLimit.project.allowed).joined(separator: ", ")
            throw JSONRPCError(code: DaemonAPI.Failure.workflowLimitReached,
                               message: """
                                \(WorkflowLimit.project.remedy). Nothing was written: \
                                \(names) are waiting for their OK in this project. Change one \
                                of those instead, or ask them to approve or remove one to \
                                make room.
                                """)
        }
        if !exists, ceilings.approved.count >= WorkflowLimit.total.allowed {
            throw JSONRPCError(code: DaemonAPI.Failure.workflowLimitReached,
                               message: """
                                Nothing was written: \(WorkflowLimit.total.allowed) \
                                workflows are already running across their projects, which \
                                is as many as this app runs at once. Ask them to archive \
                                one — anywhere — to make room.
                                """)
        }
        // The switch and the archive are the person's, and live in the file (#125), so
        // the app keeps them whatever the agent's text says. A new one starts off
        // (#124), so the person turns it on knowingly rather than finding it ran the
        // moment they approved it; no front matter the agent chooses can opt it out.
        // A change to one that exists leaves its switch and archive where they were.
        // Everything else is written exactly as it was handed over: nothing is
        // re-serialised from the parsed form, which is what makes a key this version
        // does not know survive being written by an agent running against a later one.
        var text = content
        do {
            let off = existing?.isOff ?? true
            if parsed.isOff != off { text = try WorkflowSwitches.setting(enabled: !off, in: text) }
            if let existing, parsed.isArchived != existing.isArchived {
                text = try WorkflowSwitches.setting(archived: existing.isArchived, in: text)
            }
        } catch let refusal as FrontMatterEdit.Refusal {
            throw JSONRPCError(code: DaemonAPI.Failure.workflowUnreadable,
                               message: "Nothing was written: \(refusal.message).")
        }
        try FileManager.default.createDirectory(at: WorkflowFile.folder(in: project),
                                                withIntermediateDirectories: true)
        let digest = ContentDigest.sha256(Data(text.utf8))
        var records = workflowStore.load()
        records.update(folder: project, workflowID: workflowID) {
            if !exists {
                $0.offBy = .writtenByAgent
                $0.offDigest = digest
                $0.heldFire = nil
            } else if let existingText, $0.offDigest == ContentDigest.sha256(Data(existingText.utf8)) {
                // Who turned it off has not changed with its text. Its approval has.
                $0.offDigest = digest
            }
        }
        try keep("this workflow's settings") { try workflowStore.save(records) }
        try Data(text.utf8).write(to: url, options: .atomic)
        // An archived id written to again stays archived. The one thing the person can
        // say about a workflow they did not ask for should not be undone by the agent
        // that wrote it.
        let archived = isArchived
        rescanWorkflows(in: project)
        let warning = [neverHere(parsed), unofferedWarning(for: parsed)].compactMap { $0 }
            .map { " " + $0 }.joined()
        let startsOff = exists ? "" : " It starts turned off (the app wrote `enabled: false` into it): once they have approved it, they turn it on from its page when they are ready, and you cannot."
        if archived {
            return """
                \(exists ? "Changed" : "Created") \(workflowID). \(parsed.summary). \
                It is archived, though, so it will not run until they bring it back \
                from the project page. Tell them it is there.
                """ + warning
        }
        // Waiting for the person, which is the usual case for a file an agent wrote:
        // said plainly, so the agent tells them rather than believing it will run.
        records = workflowStore.load()
        if let written = workflow(workflowID, in: project),
           awaitingApproval(written, state: records.state(folder: project, workflowID: workflowID),
                            records: records) != nil {
            return """
                \(exists ? "Changed" : "Created") \(workflowID). \(parsed.summary). \
                It will not run until they approve it on the project page, so tell them \
                it is waiting for their OK and what it does.
                """ + startsOff + warning
        }
        if !exists {
            return """
                Created \(workflowID). \(parsed.summary). \
                It is turned off (the app wrote `enabled: false` into it), so none of its \
                triggers run it until they turn it on \
                from the project page, where they can also run it, or archive it if it \
                is not what they wanted. Tell them it is there and what it does.
                """ + warning
        }
        return """
            \(exists ? "Changed" : "Created") \(workflowID). \(parsed.summary). \
            It is live now; it shows on the project page, where they can run it, or \
            archive it if it is not what they wanted.
            """ + warning
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

    // MARK: On and off (#100)

    /// Turn one off, or back on. Off is always allowed: it is the safe direction, and
    /// an agent that sees a workflow misbehaving should be able to stop it. On is
    /// allowed only for one an agent turned off: what the person turned off stays off
    /// until they turn it back on, as an archived workflow stays archived.
    private func enableWorkflowForAgent(_ workflowID: String?, enabled: Bool,
                                        in project: URL) throws -> String {
        let url = try workflowURL(workflowID, in: project)
        let id = url.deletingPathExtension().lastPathComponent
        guard let found = workflow(id, in: project) else {
            throw JSONRPCError(code: DaemonAPI.Failure.noSuchWorkflow,
                               message: "There is no workflow called \(id) in this project.")
        }
        let state = workflowStore.load().state(folder: project, workflowID: id)
        let isOff = found.isOff
        if enabled, !isOff { return "\(id) is already on." }
        if !enabled, isOff { return "\(id) is already turned off." }
        // Only what an agent turned off, on this host, in the file as it stands: a file
        // that says `enabled: false` for any other reason is waiting for the person.
        switch WorkflowState.offReason(found, state, digest: workflowDigest(found)) {
        case .file? where enabled:
            throw JSONRPCError(code: DaemonAPI.Failure.workflowTurnedOffByPerson,
                               message: """
                                Nothing was changed: \(id)'s file says `enabled: false`, so it \
                                stays off until the person turns it on from the project page. \
                                Ask them to if it should run.
                                """)
        case .writtenByAgent? where enabled:
            throw JSONRPCError(code: DaemonAPI.Failure.workflowTurnedOffByPerson,
                               message: """
                                Nothing was changed: \(id) was written by an agent, so it \
                                starts off until the person turns it on from its page. Ask \
                                them to if it should run.
                                """)
        case .person? where enabled:
            throw JSONRPCError(code: DaemonAPI.Failure.workflowTurnedOffByPerson,
                               message: """
                                Nothing was changed: \(id) was turned off by the person, so \
                                only they can turn it back on, from the project page. Ask \
                                them to if it should run again.
                                """)
        default:
            break
        }
        let summary = try setWorkflowEnabled(
            DaemonAPI.WorkflowEnableRequest(folder: project, workflowID: id, enabled: enabled),
            byAgent: true)
        guard enabled else {
            return """
                Turned off \(id). None of its triggers will run it until it is turned back \
                on; it stays on the project page, marked off, where Run now still runs it. \
                Tell them you turned it off and why.
                """
        }
        let waiting = summary.awaitingApproval != nil
            ? " It is still waiting for their OK, so it will not run until they approve it." : ""
        return "Turned \(id) back on. Its triggers run it again." + waiting
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
