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
        // The commands arrive as an update a moment after the session exists rather
        // than with it, so a new chat waits briefly for them. Half a second is the
        // difference between a prompt that knows what it takes and one that learns
        // after the first thing is typed into it.
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(500))
        while await session.commands.isEmpty, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(25))
        }
        return DaemonAPI.OptionsResponse(draftID: draftID,
                                         options: await session.options,
                                         commands: await session.commands)
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
                          availableCommands: await session.commands,
                          endedReason: .endTurn,
                          additionalDirectories: request.additionalDirectories,
                          mcpServers: request.mcpServers)
        agents[agent.id] = agent
        try await store.save(agent)
        live[agent.id] = session
        listen(to: session, agentID: agent.id)

        await session.apply(request.startOptions)
        agent = agents[agent.id] ?? agent
        changed(agent)

        await beginTurn(agentID: agent.id, text: request.prompt,
                        blocks: request.blocks, session: session)
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
            let handshake = try await session.initialize()
            let result = try await session.newSession(cwd: cwd)
            noteAccount(runtimeID: runtimeID, from: handshake)
            return (session, result.sessionId, runtime)
        } catch let error as JSONRPCError where error.isAuthRequired {
            markNeedsSignIn(runtimeID: runtimeID)
            // Not a fault. The runtime is there and needs signing in, which is
            // something the app can show and offer to fix.
            throw signInNeeded(runtime: runtime, because: error.message)
        } catch ACPSessionError.needsSignIn {
            markNeedsSignIn(runtimeID: runtimeID)
            throw signInNeeded(runtime: runtime, because: "it is not signed in")
        } catch ACPSessionError.unsupportedProtocolVersion(let version) {
            throw JSONRPCError(code: DaemonAPI.Failure.wrongProtocolVersion,
                               message: "\(runtime.name) speaks protocol version \(version), and this app speaks \(ACP.protocolVersion).")
        } catch let error as JSONRPCError {
            throw JSONRPCError(code: DaemonAPI.Failure.runtimeWillNotStart,
                               message: "\(runtime.name) would not start a session: \(error.message)")
        } catch {
            throw JSONRPCError(code: DaemonAPI.Failure.runtimeWillNotStart,
                               message: "\(runtime.name) would not start: \(error.localizedDescription)")
        }
    }

    /// The runtime is installed and unusable until somebody signs in. Its own auth
    /// methods go back with the error, including the command Copilot names, because
    /// inventing that advice ourselves would be worse than repeating theirs.
    private func signInNeeded(runtime: Runtime, because reason: String) -> JSONRPCError {
        let account = accounts[runtime.id]
        let methods = account?.authMethods ?? []
        return JSONRPCError(code: DaemonAPI.Failure.needsSignIn,
                            message: "\(runtime.name) needs signing in: \(reason)",
                            data: ["runtimeID": .string(runtime.id),
                                   "authMethods": (try? JSONValue.encoding(methods)) ?? .array([])])
    }

    // MARK: Prompting, including picking an agent back up

    /// A prompt is either sent now or joins the queue. It is never refused for want of
    /// the agent being free.
    ///
    /// Typing the next thing while the agent is still working is how people use these:
    /// the thought arrives when it arrives. The queue is ours rather than the
    /// runtime's, because a `session/prompt` sent mid-turn means something different
    /// to each of the three and none of that belongs in the window.
    public func prompt(_ request: DaemonAPI.PromptRequest) async throws {
        guard var agent = agents[request.agentID] else {
            throw JSONRPCError(code: DaemonAPI.Failure.noSuchAgent, message: "That agent is not here.")
        }
        // Everything goes on the queue, even when it is going straight out again.
        // That is what keeps the order the order it was typed in: a prompt sent while
        // three are waiting joins the back of them rather than jumping the lot.
        agent.queuedPrompts.append(QueuedPrompt(text: request.text,
                                                attachments: request.attachments))
        changed(agent)
        guard !agent.state.hasTurnInFlight, turnTasks[agent.id] == nil else { return }
        try await sendNextQueued(to: agent.id)
    }

    /// Taking one back before its turn comes. Something queued and then thought better
    /// of has to be removable, or queueing is a trap.
    public func unqueue(_ request: DaemonAPI.UnqueueRequest) async throws {
        guard var agent = agents[request.agentID] else {
            throw JSONRPCError(code: DaemonAPI.Failure.noSuchAgent, message: "That agent is not here.")
        }
        agent.queuedPrompts.removeAll { $0.id == request.promptID }
        changed(agent)
    }

    /// Send the next thing waiting, if the agent is free to take it.
    ///
    /// One at a time. Each queued prompt is a turn of its own, so the transcript reads
    /// the way it would have if the user had waited, and the agent is free in between.
    /// The runtime is started before the prompt leaves the queue, so a runtime that
    /// will not start leaves the words exactly where they were.
    func sendNextQueued(to agentID: UUID) async throws {
        guard let agent = agents[agentID], !agent.state.hasTurnInFlight,
              turnTasks[agentID] == nil, let next = agent.queuedPrompts.first else { return }
        let session = try await liveSession(for: agent)
        guard var agent = agents[agentID],
              let index = agent.queuedPrompts.firstIndex(where: { $0.id == next.id }) else { return }
        agent.queuedPrompts.remove(at: index)
        changed(agent)
        await beginTurn(agentID: agentID, text: next.text, blocks: next.blocks, session: session)
    }

    /// Whatever is waiting, now that a turn has ended of its own accord.
    ///
    /// Not after the user stopped it: stop means stop, and the queue stays put for
    /// them to send or throw away themselves.
    func drainQueue(after agentID: UUID) async {
        guard agents[agentID]?.endedReason != .cancelled else { return }
        do {
            try await sendNextQueued(to: agentID)
        } catch {
            await record(.runtimeNote("Could not send what you queued: \(reason(error)) It is still waiting."),
                         for: agentID)
        }
    }

    private func reason(_ error: any Error) -> String {
        (error as? JSONRPCError)?.message ?? error.localizedDescription
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
        updated.availableCommands = await session.commands
        changed(updated)
        await session.apply(updated.startOptions)
        live[agent.id] = session
        listen(to: session, agentID: agent.id)
        return session
    }

    // MARK: The turn itself

    func beginTurn(agentID: UUID, text: String, blocks: [ContentBlock]? = nil,
                   session: ACPSession) async {
        let blocks = blocks ?? [.text(text)]
        // The text is kept beside the blocks so the record reads the way it always has.
        await record(.userMessage(text, blocks: blocks.count > 1 ? blocks : []), for: agentID)
        await move(agentID, on: .promptSent)
        turnTasks[agentID]?.cancel()
        turnTasks[agentID] = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await session.prompt(blocks)
                await self.finishTurn(agentID: agentID, result: result)
            } catch {
                await self.turnFailed(agentID: agentID, error: error)
            }
        }
    }

    private func finishTurn(agentID: UUID, result: TurnResult) async {
        turnTasks.removeValue(forKey: agentID)
        if let usage = result.usage {
            await record(.usageRecorded(usage), for: agentID)
            if var agent = agents[agentID] {
                agent.lastTurnUsage = usage
                if let cost = usage.cost {
                    // Per currency. Adding two currencies would be a number nobody
                    // could check.
                    agent.costToDate[cost.currency] = (agent.costToDate[cost.currency] ?? 0) + cost.amount
                }
                changed(agent)
            }
        }
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
        await drainQueue(after: agentID)
    }

    private func turnFailed(agentID: UUID, error: any Error) async {
        turnTasks.removeValue(forKey: agentID)
        await record(.runtimeNote("The runtime stopped answering: \(error)."), for: agentID)
        await move(agentID, on: .processDied, endedReason: .processDied)
        await releaseRuntime(for: agentID)
        // Picking the agent back up is what any prompt does, so what was queued still
        // goes. A runtime that fell over is not a reason to lose what somebody typed.
        await drainQueue(after: agentID)
    }

    func releaseRuntime(for agentID: UUID) async {
        guard let session = live[agentID] else { return }
        forget(agentID)
        await session.end(gracePeriod: .seconds(3))
    }

    // MARK: Stopping, archiving, picking back up

    public func stop(_ agentID: UUID) async throws {
        guard var agent = agents[agentID] else {
            throw JSONRPCError(code: DaemonAPI.Failure.noSuchAgent, message: "That agent is not here.")
        }
        // Written down before anything here is awaited. The turn unwinds on its own
        // task, and whichever of the two gets there first, it has to be able to see
        // that this was the user's doing and leave the queue alone.
        if agent.state.hasTurnInFlight {
            agent.endedReason = .cancelled
            agents[agentID] = agent
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
        // Stop means stop. What was queued is kept rather than sent on: the user says
        // when it goes, and the window keeps showing them it is there.
        if !agent.queuedPrompts.isEmpty {
            let count = agent.queuedPrompts.count
            await record(.runtimeNote(count == 1
                ? "The message you queued was not sent, because you stopped it. It is still waiting."
                : "The \(count) messages you queued were not sent, because you stopped it. They are still waiting."),
                         for: agentID)
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
