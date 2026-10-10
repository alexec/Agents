import Foundation

/// The jobs `finish_turn` used to carry, each on a tool of its own (#481).
///
/// A request to archive, a move and the end of a wait all happen once the turn ends, so each tool records
/// its effect on the agent for then, and a conflict between two is refused by the second,
/// in a sentence saying why. Only the wait ends the turn (#139), as `blocked` did: requests,
/// labels and moves leave the agent to carry on.
///
/// - a request to archive and a move go together: the agent moves, and stays there
///   asking rather than being started again.
/// - a wait does not go with a move (a move starts the agent again elsewhere) or an
///   archive; a wait does not go with a request either, since one asking to be archived
///   is not waiting to be woken.
extension DaemonCore {
    /// `request_archive` or `archive_agent` with no id: put this agent away once its turn ends.
    public func askAfterTurn(_ request: DaemonAPI.AfterTurnRequest) throws -> String {
        guard let agentID = appTokens[request.token], var agent = agents[agentID] else {
            throw JSONRPCError(code: DaemonAPI.Failure.noSuchAgent,
                               message: "That conversation is not open any more, so nothing was recorded.")
        }
        guard let after = AfterTurn(wire: request.afterwards) else {
            throw JSONRPCError(code: JSONRPCError.invalidParams, message: AfterTurn.unknown)
        }
        if after == .archive {
            guard whenDone(forRunOf: agentID)?.allowsArchiveAsk == true else {
                throw JSONRPCError(code: DaemonAPI.Failure.notYours, message: Self.cannotArchiveItself)
            }
            guard agent.pendingMove == nil else {
                throw JSONRPCError(code: JSONRPCError.invalidParams, message: """
                    Nothing was recorded: you move once this turn ends, and a run that \
                    moves is not archived. Call move_worktree with neither argument to \
                    stay, or call request_archive instead.
                    """)
            }
        }
        // An ending this turn has already given, which the ask must go with.
        if let report = agent.report, report != reportBeforeTurn[agentID], !after.goes(with: report.outcome) {
            let wait = report.outcome == .blocked
                ? " You are waiting to be resumed, and a conversation asking to be archived is not." : ""
            throw JSONRPCError(code: JSONRPCError.invalidParams,
                               message: "Nothing was recorded: this turn ended \(report.outcome.rawValue), "
                                   + "and \(after.rawValue) only goes with "
                                   + (after == .requestArchive ? "done, nothing_to_do or partly_done." : "done or nothing_to_do.")
                                   + wait)
        }
        if let wait = agent.eventWait, wait.isOpen {
            throw JSONRPCError(code: JSONRPCError.invalidParams, message: """
                Nothing was recorded: you are waiting for \(wait.label), and a conversation \
                asking to be archived is not waiting to be woken. Call cancel_wait first.
                """)
        }
        agent.afterTurn = after
        changed(agent)
        var note = Self.afterTurnNote(after)
        if after == .requestArchive, agent.pendingMove != nil {
            note += " You move first, and stay there asking rather than being started again."
        } else if after == .requestArchive, let say = archivesWithoutAskingNote(agentID, agent) {
            note = say
        }
        return note + " Anything the person sends before then drops it."
    }

    /// What an agent asking to be archived is told when nobody needs to agree (#584,
    /// decision 2): its workflow lets its run archive itself, or the agent that
    /// started it may archive it. Nil when the person is asked.
    private func archivesWithoutAskingNote(_ agentID: UUID, _ agent: Agent) -> String? {
        let may = whenDone(forRunOf: agentID)?.allowsArchiveAsk == true
            || (agent.startedByAgent != nil && agentsMayArchive(in: agent.projectFolder))
        guard may else { return nil }
        return "Once this turn ends, this conversation will be archived if it ended done or with nothing to do, "
            + "as nobody needs to agree; otherwise the person will be asked."
    }

    /// `set_session_labels`: the agent's own labels, changed now.
    public func setSessionLabels(_ request: DaemonAPI.OwnLabelsRequest) throws -> String {
        guard let agentID = appTokens[request.token], var agent = agents[agentID] else {
            throw JSONRPCError(code: DaemonAPI.Failure.noSuchAgent,
                               message: "That conversation is not open any more, so nothing was changed.")
        }
        guard !request.add.isEmpty || !request.remove.isEmpty else {
            throw JSONRPCError(code: JSONRPCError.invalidParams,
                               message: "Nothing changed: give labels in add, remove, or both.")
        }
        do {
            agent.labels = try SessionLabelPolicy.change(
                current: agent.labels, add: request.add, remove: request.remove, actor: .agent,
                projectLabels: SessionLabelPolicy.vocabulary(
                    in: agent.projectFolder, agents: agents.inProject(agent.projectFolder)))
        } catch {
            throw JSONRPCError(code: JSONRPCError.invalidParams,
                               message: "Nothing changed: \(error.localizedDescription)")
        }
        changed(agent)
        let now = agent.labels.map(\.value)
        return now.isEmpty ? "This session has no labels now." : "This session's labels: \(now.joined(separator: ", "))."
    }

    /// `wait_for_event` on agents, or on a time alone: the block `finish_turn` recorded with
    /// `blocked`, and like it the end of the turn.
    public func waitOn(_ request: DaemonAPI.WaitOnRequest) async throws -> String {
        guard let agentID = appTokens[request.token], let agent = agents[agentID] else {
            throw JSONRPCError(code: DaemonAPI.Failure.noSuchAgent,
                               message: "That conversation is not open any more, so nothing is waited for.")
        }
        let names = request.agents.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        // Every wait ends by itself (#572): a helper still running when it does is
        // seen, and waited on again.
        guard request.untilMinutes != nil else {
            throw JSONRPCError(code: JSONRPCError.invalidParams,
                               message: "Nothing is waited for: " + EventWords.deadlineRequired())
        }
        if agent.pendingMove?.askedBy == .agent {
            throw JSONRPCError(code: JSONRPCError.invalidParams, message: """
                Nothing is waited for: you move once this turn ends, and are started again \
                there. Call move_worktree with neither argument to stay, then wait.
                """)
        }
        if agent.afterTurn == .archive {
            throw JSONRPCError(code: JSONRPCError.invalidParams, message: """
                Nothing is waited for: you asked to be archived once this turn ends, and an \
                archived run is never woken.
                """)
        }
        let given = request.message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let message = !given.isEmpty ? given
            : names.isEmpty ? "Waiting, to check again in \(request.untilMinutes ?? 0) minutes."
            : "Waiting for other agents to finish."
        return try await finishTurn(DaemonAPI.FinishTurnRequest(
            token: request.token, outcome: WorkOutcome.blocked.rawValue, message: message, prompts: [],
            waitingOn: names.isEmpty ? nil : names, checkAgainInMinutes: request.untilMinutes,
            wakeOn: request.wakeOn))
    }
}
