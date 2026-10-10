import Foundation

/// The jobs `finish_turn` used to carry, each on a tool of its own (#481).
///
/// Park, move and the end of a wait all happen once the turn ends, so each tool records
/// its effect on the agent for then, and a conflict between two is refused by the second,
/// in a sentence saying why. Only the wait ends the turn (#139), as `blocked` did: park,
/// labels and moves leave the agent to carry on.
///
/// - park and a move go together: the agent moves, and stays parked there rather than
///   being started again.
/// - a wait does not go with a move (a move starts the agent again elsewhere) or an
///   archive; a wait drops an ask to be parked, since a parked agent is never woken.
extension DaemonCore {
    /// `park_agent` or `archive_agent` with no id: put this agent away once its turn ends.
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
                    stay, or park instead.
                    """)
            }
        }
        // An ending this turn has already given, which the ask must go with.
        if let report = agent.report, report != reportBeforeTurn[agentID], !after.goes(with: report.outcome) {
            let wait = report.outcome == .blocked
                ? " You are waiting to be resumed, and a parked conversation is never woken." : ""
            throw JSONRPCError(code: JSONRPCError.invalidParams,
                               message: "Nothing was recorded: this turn ended \(report.outcome.rawValue), "
                                   + "and \(after.rawValue) only goes with "
                                   + (after == .park ? "done, nothing_to_do or partly_done." : "done or nothing_to_do.")
                                   + wait)
        }
        if let wait = agent.eventWait, wait.isOpen {
            throw JSONRPCError(code: JSONRPCError.invalidParams, message: """
                Nothing was recorded: you are waiting for \(wait.label), and a parked \
                conversation is never woken. Call cancel_wait first.
                """)
        }
        agent.afterTurn = after
        changed(agent)
        var note = Self.afterTurnNote(after)
        if after == .park, agent.pendingMove != nil {
            note += " You move first, and stay parked there rather than being started again."
        }
        return note + " Anything the person sends before then drops it."
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
