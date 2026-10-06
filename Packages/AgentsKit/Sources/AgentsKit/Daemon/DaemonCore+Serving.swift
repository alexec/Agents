import Foundation

/// What the daemon does when an agent asks the app for something.
///
/// Files, terminals and forms. All three are the daemon's rather than a window's, for
/// the same reason the agents are: the request can arrive while no window is open, and
/// something has to hold it, answer it, and still be there afterwards.
extension DaemonCore {
    struct PendingElicitation: Sendable {
        var request: ElicitationRequest
        var agentID: UUID
    }

    // MARK: Forms

    public func pendingElicitations() -> [ElicitationRequest] {
        elicitations.values.map(\.request).sorted { $0.askedAt < $1.askedAt }
    }

    public func answerElicitation(_ request: DaemonAPI.AnswerElicitationRequest) async throws {
        guard let pending = elicitations[request.requestID] else {
            throw JSONRPCError(code: DaemonAPI.Failure.noSuchAgent,
                               message: "That form has already been answered.")
        }
        let outcome: ElicitationOutcome
        switch request.action {
        case .accept:
            if case .form(let schema) = pending.request.mode {
                // An answer that does not fit the shape is not sent. The agent asked
                // for something specific and half of it is worse than none. The form
                // is still waiting afterwards rather than lost.
                let problems = schema.problems(with: request.content)
                guard problems.isEmpty else {
                    throw JSONRPCError(code: JSONRPCError.invalidParams,
                                       message: problems.joined(separator: ". "))
                }
            }
            outcome = .accept(request.content)
        case .decline:
            outcome = .decline
        case .cancel:
            outcome = .cancel
        }
        elicitations.removeValue(forKey: request.requestID)
        let turnIsLive = turnTasks[pending.agentID] != nil
        if turnIsLive, let session = live[pending.agentID] {
            await session.answerElicitation(id: pending.request.id, outcome: outcome)
        }
        var answers: [ElicitationAnswer] = []
        if case .accept(let content) = outcome, case .form(let schema) = pending.request.mode {
            answers = schema.answers(content, message: pending.request.message)
        }
        // An `ask_form` call is waiting on this same id: wake it with the words the
        // agent reads, then carry on as a runtime elicitation would.
        answerAsk(pending.request.id, .success(Self.askFormNote(outcome: outcome, answers: answers)))
        // A warm session is not a turn. Preserve the question beside the answer and
        // start a fresh turn through the same durable queue as an ordinary prompt.
        let shouldResume: Bool
        if case .cancel = outcome { shouldResume = false } else { shouldResume = true }
        if !turnIsLive, shouldResume, agents[pending.agentID] != nil {
            let properties: [String?]
            if case .form(let schema) = pending.request.mode {
                properties = schema.properties.map(\.title)
            } else {
                properties = []
            }
            let question = ([pending.request.message ?? pending.request.title] + properties)
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
            let asked = question.isEmpty ? "The agent asked a question." : question
            let response = Self.askFormNote(outcome: outcome, answers: answers)
            let text = "The agent asked:\n\(asked)\n\nYour answer: \(response)"
            let prompt = DaemonAPI.PromptRequest(agentID: pending.agentID, text: text, from: .app)
            try await keepPrompt(prompt)
            try await enqueue(prompt, first: false)
        }
        await record(.elicitationAnswered(id: pending.request.id, summary: outcome.summary,
                                          answers: answers),
                     for: pending.agentID)
        await move(pending.agentID, on: .permissionAnswered)
        broadcast(DaemonAPI.Notification.agentElicitation,
                  DaemonAPI.ElicitationNotification(agentID: pending.agentID,
                                                    requestID: pending.request.id,
                                                    request: nil))
        reconsider()
    }

    /// What `ask_form` returns once the person has answered, skipped or cancelled.
    static func askFormNote(outcome: ElicitationOutcome, answers: [ElicitationAnswer]) -> String {
        switch outcome {
        case .accept:
            guard !answers.isEmpty else { return "They sent an empty answer." }
            return "They answered:\n"
                + answers.map { "- \($0.question): \($0.answer)" }.joined(separator: "\n")
        case .decline:
            return "They skipped the questions."
        case .cancel:
            return "They cancelled."
        }
    }

    /// Resume an `ask_form` call waiting on this elicitation, if any.
    func answerAsk(_ requestID: UUID, _ result: Result<String, JSONRPCError>) {
        openAsks.removeValue(forKey: requestID)?.resume(returning: result)
    }

    func holdElicitation(_ request: ElicitationRequest, agentID: UUID) async {
        guard turnTasks[agentID] != nil else {
            await record(.runtimeNote(RuntimeNote.questionWentUnanswered), for: agentID)
            if let session = live[agentID] {
                await session.answerElicitation(id: request.id, outcome: .cancel)
            }
            return
        }
        var request = request
        request.agentID = agentID
        elicitations[request.id] = PendingElicitation(request: request, agentID: agentID)
        await record(.elicitationAsked(request), for: agentID)
        await move(agentID, on: .permissionAsked)
        broadcast(DaemonAPI.Notification.agentElicitation,
                  DaemonAPI.ElicitationNotification(agentID: agentID, requestID: request.id,
                                                    request: request))
        reconsider()
    }

    /// The runtime took its own form down — answered somewhere else, or it changed its
    /// mind. Everything an answer would have done still has to happen: the record
    /// closes, the agent comes back out of "Needs attention", the windows hear. Left
    /// out, the agent sat under that heading with nothing on the page to answer and
    /// no way out but stopping it.
    ///
    /// The state moves before the form is dropped, not after: each `await` here is a
    /// place a window can look, and a window that sees no form must not see an agent
    /// still waiting on one.
    func withdrawElicitation(_ requestID: UUID, agentID: UUID) async {
        guard elicitations[requestID] != nil else { return }
        await record(.elicitationAnswered(id: requestID, summary: ElicitationOutcome.cancel.summary),
                     for: agentID)
        await move(agentID, on: .permissionAnswered)
        elicitations.removeValue(forKey: requestID)
        answerAsk(requestID, .success("They cancelled."))
        broadcast(DaemonAPI.Notification.agentElicitation,
                  DaemonAPI.ElicitationNotification(agentID: agentID, requestID: requestID, request: nil))
        reconsider()
    }

    // MARK: Terminals

    /// The terminals this agent has open, made on first use so an agent that never asks
    /// for one costs nothing.
    func terminals(for agentID: UUID) -> TerminalService {
        if let existing = terminalServices[agentID] { return existing }
        let agent = agents[agentID]
        let scope = agent?.folderScope ?? FolderScope(folders: [])
        // The box, not the door: a terminal made before the socket is open — during
        // recovery, say — still finds the way out once there is one.
        let addressed = addressed
        let showing = showing
        let service = TerminalService(scope: scope,
                                      defaultCWD: agent?.cwd ?? locations.root) { terminalID, chunk in
            // Output goes straight to the windows as it arrives, so a long command
            // reads like a terminal rather than appearing all at once at the end. Only
            // to those showing the agent (#203); one that opens it later is sent what the
            // terminal still holds (`sendTerminals`).
            let showers = showing.connections(showing: agentID)
            guard addressed.isSet, !showers.isEmpty else { return }
            let notification = DaemonAPI.TerminalOutputNotification(agentID: agentID,
                                                                   terminalID: terminalID,
                                                                   chunk: chunk)
            addressed(DaemonAPI.Notification.agentTerminalOutput,
                      try? JSONValue.encoding(notification), to: { showers.contains($0.id) })
        }
        terminalServices[agentID] = service
        return service
    }

    /// What each of the agent's terminals still holds, to a connection that has just opened
    /// it (#203): the output it was not sent while it showed something else.
    func sendTerminals(of agentID: UUID, to connection: UUID) async {
        guard let service = terminalServices[agentID] else { return }
        for (terminalID, output) in await service.held() where !output.isEmpty {
            send(DaemonAPI.Notification.agentTerminalOutput,
                 DaemonAPI.TerminalOutputNotification(agentID: agentID, terminalID: terminalID,
                                                      chunk: output, whole: true),
                 to: { $0.id == connection })
        }
    }

    /// Everything this agent started, stopped. An agent that is not running has no
    /// business still running commands.
    func killTerminals(for agentID: UUID) async {
        guard let service = terminalServices.removeValue(forKey: agentID) else { return }
        await service.killAll()
    }

    func killAllTerminals() async {
        for (_, service) in terminalServices { await service.killAll() }
        terminalServices.removeAll()
    }

    /// Tell a session what its agent may reach, and hand it the terminals it may use.
    func prepareServing(_ session: ACPSession, agentID: UUID) async {
        guard let agent = agents[agentID] else { return }
        await session.serve(scope: agent.folderScope, terminals: terminals(for: agentID))
    }
}
