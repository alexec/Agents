import Foundation

extension DaemonCore {
    // MARK: Starting

    /// Step one of starting an agent: make a session so its options can be shown.
    ///
    /// The options only exist once `session/new` has answered, so a session is created
    /// before the user has chosen anything. It is kept as a draft and used by the
    /// start that follows, so the runtime is started once and the user sees one dialog.
    public func options(_ request: DaemonAPI.OptionsRequest) async throws -> DaemonAPI.OptionsResponse {
        let (session, sessionID, _) = try await freshSession(runtimeID: request.runtimeID, cwd: request.cwd)
        let draftID = UUID()
        drafts[draftID] = Draft(runtimeID: request.runtimeID, cwd: request.cwd,
                                session: session, sessionID: sessionID)
        return DaemonAPI.OptionsResponse(draftID: draftID, options: await session.options)
    }

    public func start(_ request: DaemonAPI.StartRequest) async throws -> UUID {
        let session: ACPSession
        let sessionID: String
        if let draftID = request.draftID, let draft = drafts.removeValue(forKey: draftID),
           draft.runtimeID == request.runtimeID, draft.cwd == request.cwd {
            session = draft.session
            sessionID = draft.sessionID
        } else {
            (session, sessionID, _) = try await freshSession(runtimeID: request.runtimeID, cwd: request.cwd)
        }

        var agent = Agent(runtimeID: request.runtimeID,
                          cwd: request.cwd,
                          title: Agent.fallbackTitle(from: request.prompt),
                          state: .stopped,
                          runtimeSessionID: sessionID,
                          startOptions: request.startOptions,
                          advertisedOptions: await session.options,
                          endedReason: .endTurn)
        agents[agent.id] = agent
        try await store.save(agent)
        live[agent.id] = session
        listen(to: session, agentID: agent.id)

        await session.apply(request.startOptions)
        agent = agents[agent.id] ?? agent
        changed(agent)

        await beginTurn(agentID: agent.id, text: request.prompt, session: session)
        return agent.id
    }

    /// A folder, a runtime, and a handshake. Everything that can go wrong here is
    /// something the user needs told rather than a log line.
    private func freshSession(runtimeID: String, cwd: URL) async throws -> (ACPSession, String, Runtime) {
        guard let runtime = RuntimeCatalog.runtime(id: runtimeID) else {
            throw JSONRPCError(code: DaemonAPI.Failure.runtimeNotFound,
                               message: "There is no runtime called \(runtimeID).")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cwd.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw JSONRPCError(code: DaemonAPI.Failure.folderGone,
                               message: "\(cwd.path) is not there any more.")
        }
        guard case .available(let path, _) = discovery.locate(runtime) else {
            throw JSONRPCError(code: DaemonAPI.Failure.runtimeNotFound,
                               message: "\(runtime.name) is not installed, or is not where we looked.",
                               data: ["lookedIn": .array(discovery.searchPaths.map(JSONValue.string))])
        }
        do {
            let session = try launcher.launch(runtime: runtime, path: path, cwd: cwd)
            _ = try await session.initialize()
            let result = try await session.newSession(cwd: cwd)
            return (session, result.sessionId, runtime)
        } catch let error as JSONRPCError {
            throw JSONRPCError(code: DaemonAPI.Failure.runtimeWillNotStart,
                               message: "\(runtime.name) would not start a session: \(error.message)")
        } catch {
            throw JSONRPCError(code: DaemonAPI.Failure.runtimeWillNotStart,
                               message: "\(runtime.name) would not start: \(error.localizedDescription)")
        }
    }

    // MARK: Prompting, including picking an agent back up

    public func prompt(_ request: DaemonAPI.PromptRequest) async throws {
        guard let agent = agents[request.agentID] else {
            throw JSONRPCError(code: DaemonAPI.Failure.noSuchAgent, message: "That agent is not here.")
        }
        guard agent.state != .running else {
            throw JSONRPCError(code: DaemonAPI.Failure.alreadyRunning,
                               message: "That agent is already working. Wait for it, or stop it.")
        }
        let session = try await liveSession(for: agent)
        await beginTurn(agentID: agent.id, text: request.text, session: session)
    }

    /// The session an agent is using, starting its runtime again if it has none.
    ///
    /// This is picking an agent up: same agent, same folder, same conversation, with a
    /// new process behind it and possibly a new runtime session recorded against it.
    private func liveSession(for agent: Agent) async throws -> ACPSession {
        if let existing = live[agent.id] { return existing }
        guard let runtime = RuntimeCatalog.runtime(id: agent.runtimeID) else {
            throw JSONRPCError(code: DaemonAPI.Failure.runtimeNotFound,
                               message: "There is no runtime called \(agent.runtimeID).")
        }
        guard case .available(let path, _) = discovery.locate(runtime) else {
            throw JSONRPCError(code: DaemonAPI.Failure.runtimeNotFound,
                               message: "\(runtime.name) is not installed any more.")
        }
        await record(.runtimeNote("Starting \(runtime.name)…"), for: agent.id)
        let session = try launcher.launch(runtime: runtime, path: path, cwd: agent.cwd)
        _ = try await session.initialize()

        var updated = agent
        if let sessionID = agent.runtimeSessionID {
            do {
                try await session.continueSession(id: sessionID, cwd: agent.cwd)
                await record(.runtimeNote("Picked the conversation back up."), for: agent.id)
            } catch {
                // The runtime no longer has it. The agent is not lost: it carries on as
                // the same agent, with our transcript, in a new runtime session.
                await record(.runtimeNote("\(runtime.name) no longer has this conversation. Carrying on in a new one; everything above is kept."),
                             for: agent.id)
                let result = try await session.newSession(cwd: agent.cwd)
                updated.runtimeSessionID = result.sessionId
            }
        } else {
            let result = try await session.newSession(cwd: agent.cwd)
            updated.runtimeSessionID = result.sessionId
        }
        updated.advertisedOptions = await session.options
        changed(updated)
        await session.apply(updated.startOptions)
        live[agent.id] = session
        listen(to: session, agentID: agent.id)
        return session
    }

    // MARK: The turn itself

    func beginTurn(agentID: UUID, text: String, session: ACPSession) async {
        await record(.userMessage(text), for: agentID)
        await move(agentID, on: .promptSent)
        turnTasks[agentID]?.cancel()
        turnTasks[agentID] = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await session.prompt(text)
                await self.finishTurn(agentID: agentID, result: result)
            } catch {
                await self.turnFailed(agentID: agentID, error: error)
            }
        }
    }

    private func finishTurn(agentID: UUID, result: TurnResult) async {
        turnTasks.removeValue(forKey: agentID)
        let reason: EndedReason
        if let known = result.reason {
            reason = known
        } else {
            await record(.runtimeNote("The runtime ended the turn with a stop reason we do not know: \(result.rawStopReason ?? "none")."),
                         for: agentID)
            reason = .unrecognised
        }
        await move(agentID, on: .turnEnded(reason), endedReason: reason)
        // A finished agent's process is let go: every runtime hands the session back,
        // so holding one open buys nothing and works against the daemon's exit rule.
        await releaseRuntime(for: agentID)
    }

    private func turnFailed(agentID: UUID, error: any Error) async {
        turnTasks.removeValue(forKey: agentID)
        await record(.runtimeNote("The runtime stopped answering: \(error)."), for: agentID)
        await move(agentID, on: .processDied, endedReason: .processDied)
        await releaseRuntime(for: agentID)
    }

    func releaseRuntime(for agentID: UUID) async {
        guard let session = live[agentID] else { return }
        forget(agentID)
        await session.end(gracePeriod: .seconds(3))
    }

    // MARK: Stopping, archiving, picking back up

    public func stop(_ agentID: UUID) async throws {
        guard let agent = agents[agentID] else {
            throw JSONRPCError(code: DaemonAPI.Failure.noSuchAgent, message: "That agent is not here.")
        }
        for (id, pending) in pendingPermissions where pending.agentID == agentID {
            if let session = live[agentID] {
                await session.answerPermission(id: pending.request.id, optionID: nil)
            }
            pendingPermissions.removeValue(forKey: id)
            broadcast(DaemonAPI.Notification.agentPermission,
                      DaemonAPI.PermissionNotification(agentID: agentID, request: nil))
        }
        if let session = live[agentID] { await session.cancel() }
        turnTasks.removeValue(forKey: agentID)?.cancel()
        if agent.state.holdsRuntime {
            await move(agentID, on: .stoppedByUser, endedReason: .cancelled)
        }
        await releaseRuntime(for: agentID)
    }

    public func archive(_ agentID: UUID) async throws {
        guard let agent = agents[agentID] else {
            throw JSONRPCError(code: DaemonAPI.Failure.noSuchAgent, message: "That agent is not here.")
        }
        if agent.state.holdsRuntime { try await stop(agentID) }
        await move(agentID, on: .archivedByUser)
    }

    public func unarchive(_ agentID: UUID) async throws {
        guard agents[agentID] != nil else {
            throw JSONRPCError(code: DaemonAPI.Failure.noSuchAgent, message: "That agent is not here.")
        }
        await move(agentID, on: .unarchivedByUser)
    }

    // MARK: Options and permissions

    public func setOption(_ request: DaemonAPI.SetOptionRequest) async throws -> [ConfigOption] {
        guard let session = live[request.agentID] else {
            // Nothing is running, so the choice is remembered and applied when the
            // agent is next picked up.
            guard var agent = agents[request.agentID] else {
                throw JSONRPCError(code: DaemonAPI.Failure.noSuchAgent, message: "That agent is not here.")
            }
            agent.startOptions.values[request.optionID] = request.value
            changed(agent)
            await record(.optionChanged(id: request.optionID, value: request.value), for: request.agentID)
            return []
        }
        let options = try await session.setOption(id: request.optionID, value: request.value)
        if var agent = agents[request.agentID] {
            agent.advertisedOptions = options
            agent.startOptions.values[request.optionID] = request.value
            changed(agent)
        }
        await record(.optionChanged(id: request.optionID, value: request.value), for: request.agentID)
        return options
    }

    public func answerPermission(_ request: DaemonAPI.AnswerRequest) async throws {
        guard let pending = pendingPermissions.removeValue(forKey: request.permissionID) else {
            throw JSONRPCError(code: DaemonAPI.Failure.noSuchAgent,
                               message: "That question has already been answered.")
        }
        let name = pending.request.options.first { $0.optionID == request.optionID }?.name
        if let session = live[pending.agentID] {
            await session.answerPermission(id: pending.request.id, optionID: request.optionID)
        }
        await record(.permissionAnswered(optionID: request.optionID, optionName: name), for: pending.agentID)
        await move(pending.agentID, on: .permissionAnswered)
        broadcast(DaemonAPI.Notification.agentPermission,
                  DaemonAPI.PermissionNotification(agentID: pending.agentID, request: nil))
    }

    public func transcript(_ request: DaemonAPI.TranscriptRequest) async throws -> TranscriptPage {
        try await store.transcript(for: request.agentID, before: request.before, limit: request.limit)
    }
}
