import Foundation

extension DaemonCore {
    // MARK: Starting

    /// Step one of starting an agent: make a session so its options can be shown.
    ///
    /// The options only exist once `session/new` has answered, so a session is created
    /// before the user has chosen anything. It is kept as a draft and used by the
    /// start that follows, so the runtime is started once and the user sees one dialog.
    ///
    /// Starting one takes seconds, and a runtime nearly always offers what it offered
    /// last time, so a remembered answer goes back at once and the session carries on
    /// being made behind it. What the runtime actually says is broadcast when it says
    /// it, and is what the start applies the user's choices to either way.
    public func options(_ request: DaemonAPI.OptionsRequest) async throws -> DaemonAPI.OptionsResponse {
        let draftID = UUID()
        let pending = Task { [self] in
            try await freshSession(runtimeID: request.runtimeID, cwd: request.cwd,
                                   mcpServers: request.mcpServers)
        }
        drafts[draftID] = Draft(runtimeID: request.runtimeID, cwd: request.cwd,
                                mcpServers: request.mcpServers, pending: pending)
        let key = OptionCache.key(runtimeID: request.runtimeID, cwd: request.cwd,
                                  mcpServers: request.mcpServers)
        if let remembered = rememberedOptions(for: key) {
            Task { [self] in await settleDraft(draftID, key: key, shown: remembered) }
            return DaemonAPI.OptionsResponse(draftID: draftID,
                                             options: remembered.options,
                                             commands: remembered.commands)
        }
        let advertised: OptionCache.Entry
        do {
            advertised = try await whatItOffers(pending)
        } catch {
            // A draft whose runtime never started is not a draft. Left in the map it
            // would hold the daemon open for a session that will never exist.
            drafts.removeValue(forKey: draftID)
            throw error
        }
        remember(advertised, for: key)
        return DaemonAPI.OptionsResponse(draftID: draftID,
                                         options: advertised.options,
                                         commands: advertised.commands)
    }

    /// Everything a made session advertises, once it is made.
    private func whatItOffers(_ pending: Task<MadeSession, any Error>) async throws -> OptionCache.Entry {
        let session = try await pending.value.session
        // The commands arrive as an update a moment after the session exists rather
        // than with it, so a new chat waits briefly for them. Half a second is the
        // difference between a prompt that knows what it takes and one that learns
        // after the first thing is typed into it.
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(500))
        while await session.commands.isEmpty, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(25))
        }
        return OptionCache.Entry(options: await session.options, commands: await session.commands)
    }

    /// A form was answered from memory. Wait for the runtime starting behind it, and
    /// put the window right if what it offers has moved.
    private func settleDraft(_ draftID: UUID, key: String, shown: OptionCache.Entry) async {
        guard let pending = drafts[draftID]?.pending else { return }
        do {
            let advertised = try await whatItOffers(pending)
            remember(advertised, for: key)
            // Started already: the agent carries what the session really said, and the
            // draft form it was chosen in has gone.
            guard drafts[draftID] != nil else { return }
            guard advertised.offers != shown.offers else { return }
            broadcast(DaemonAPI.Notification.draftOptions,
                      DaemonAPI.DraftOptionsNotification(draftID: draftID,
                                                         options: advertised.options,
                                                         commands: advertised.commands))
        } catch {
            drafts.removeValue(forKey: draftID)
            // The form was shown before we knew the runtime would not start, so this is
            // the only chance to say so. Without it the news arrives when the user
            // presses send, having typed a prompt first.
            broadcast(DaemonAPI.Notification.draftOptions,
                      DaemonAPI.DraftOptionsNotification(draftID: draftID,
                                                         failure: describeForWindow(error)))
        }
    }

    private func describeForWindow(_ error: any Error) -> String {
        (error as? JSONRPCError)?.message ?? error.localizedDescription
    }

    /// What this runtime and folder last advertised, if anything worth showing.
    func rememberedOptions(for key: String) -> OptionCache.Entry? {
        if rememberedOptions == nil { rememberedOptions = optionCache.load() }
        guard let entry = rememberedOptions?[key], entry.isWorthKeeping else { return nil }
        return entry
    }

    func remember(_ entry: OptionCache.Entry, for key: String) {
        guard entry.isWorthKeeping else { return }
        if rememberedOptions == nil { rememberedOptions = optionCache.load() }
        rememberedOptions?[key] = entry
        try? optionCache.save(rememberedOptions ?? [:])
    }

    public func start(_ request: DaemonAPI.StartRequest) async throws -> UUID {
        let session: ACPSession
        let sessionID: String
        let appToken: String
        // A draft is only usable if it was made with the servers this start names.
        // They are read once, when the session is made, so reusing a session that
        // never heard about a server would attach it in name only.
        let draft = request.draftID.flatMap { drafts.removeValue(forKey: $0) }
        let usable = draft.flatMap { $0.runtimeID == request.runtimeID && $0.cwd == request.cwd
                                     && $0.mcpServers == request.mcpServers ? $0 : nil }
        if let usable {
            // The session may still be being made: a form shown from memory is quicker
            // than the runtime behind it. Waiting here is waiting for the start that
            // would otherwise have happened before the form appeared.
            let made = try await usable.pending.value
            session = made.session
            sessionID = made.sessionID
            appToken = made.appToken
        } else {
            // A draft we cannot use is a runtime nobody is going to talk to. Let go of
            // in its own time: it may still be starting, and this start is not waiting
            // on a session it has already decided against.
            if let draft { Task { [self] in await endDraft(draft) } }
            let made = try await freshSession(runtimeID: request.runtimeID, cwd: request.cwd,
                                              mcpServers: request.mcpServers)
            session = made.session
            sessionID = made.sessionID
            appToken = made.appToken
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
        // The runtime was given this token before the agent existed. Now it means
        // something, and until this line a call carrying it is refused.
        bindAppToken(appToken, to: agent.id)
        // The first prompt of the conversation is the one that carries the briefing.
        needsBriefing.insert(agent.id)
        listen(to: session, agentID: agent.id)
        await prepareServing(session, agentID: agent.id)

        await session.apply(request.startOptions)
        agent = agents[agent.id] ?? agent
        changed(agent)

        await beginTurn(agentID: agent.id, text: request.prompt,
                        blocks: request.blocks, session: session)
        return agent.id
    }

    struct MadeSession: Sendable {
        var session: ACPSession
        var sessionID: String
        var runtime: Runtime
        var appToken: String
    }

    /// Let go of a draft nobody is going to use. Its session may still be being made,
    /// so the runtime is ended when it arrives rather than left running unowned.
    func endDraft(_ draft: Draft) async {
        guard let made = try? await draft.pending.value else { return }
        await made.session.end(gracePeriod: .seconds(2))
    }

    /// A folder, a runtime, and a handshake. Everything that can go wrong here is
    /// something the user needs told rather than a log line.
    private func freshSession(runtimeID: String, cwd: URL,
                              mcpServers: [MCPServer] = []) async throws -> MadeSession {
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
            // Recorded here rather than after the session is made, because the reason
            // to have it is the case where making the session fails: what comes back
            // then is "needs signing in", and the ways to sign in are in the handshake.
            noteAccount(runtimeID: runtimeID, from: handshake)
            let token = mintAppToken()
            let result = try await session.newSession(cwd: cwd,
                                                      mcpServers: mcpServers + [appServer(token: token)])
            return MadeSession(session: session, sessionID: result.sessionId,
                               runtime: runtime, appToken: token)
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
        try await enqueue(request, first: false)
    }

    /// The one prompt that goes to the front of the queue: the news, after a restart,
    /// that the turn somebody thought was still running was not.
    ///
    /// Everything else appends, deliberately. This is the exception because the words
    /// already waiting were typed by somebody who believed the turn was still in
    /// flight. Behind the restart words, the agent would act on instructions premised
    /// on a state that never existed and only afterwards be told it had been cut off
    /// — the exact thing telling it at all is for.
    func promptFirst(_ request: DaemonAPI.PromptRequest) async throws {
        try await enqueue(request, first: true)
    }

    private func enqueue(_ request: DaemonAPI.PromptRequest, first: Bool) async throws {
        guard var agent = agents[request.agentID] else {
            throw JSONRPCError(code: DaemonAPI.Failure.noSuchAgent, message: "That agent is not here.")
        }
        // Everything goes on the queue, even when it is going straight out again.
        // That is what keeps the order the order it was typed in: a prompt sent while
        // three are waiting joins the back of them rather than jumping the lot.
        let queued = QueuedPrompt(text: request.text, attachments: request.attachments)
        agent.queuedPrompts.insert(queued, at: first ? 0 : agent.queuedPrompts.endIndex)
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
              turnTasks[agentID] == nil, !sending.contains(agentID),
              let next = agent.queuedPrompts.first else { return }
        // Claimed before the runtime is started, because starting one is a long await
        // and the two callers of this can both arrive inside it: the user typing as a
        // turn ends, and that turn draining the queue behind them. Nothing else here
        // says "already going" until `beginTurn` sets the task, and by then the same
        // words have gone to two runtimes. The guard above is checked and this is set
        // without an await between them, which on an actor is the whole of the lock.
        sending.insert(agentID)
        defer { sending.remove(agentID) }
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

        // A new process is a new MCP server, so a new token. The old one stopped
        // working when the last process died.
        let token = mintAppToken()
        let servers = agent.mcpServers + [appServer(token: token)]
        bindAppToken(token, to: agent.id)

        var updated = agent
        if let sessionID = agent.runtimeSessionID {
            do {
                try await session.continueSession(id: sessionID, cwd: agent.cwd,
                                                  additionalDirectories: agent.additionalDirectories,
                                                  mcpServers: servers)
                await record(.runtimeNote("Picked the conversation back up."), for: agent.id)
            } catch {
                // The runtime no longer has it. The agent is not lost: it carries on as
                // the same agent, with our transcript, in a new runtime session.
                await record(.runtimeNote("\(runtime.name) no longer has this conversation. Carrying on in a new one; everything above is kept."),
                             for: agent.id)
                let result = try await session.newSession(cwd: agent.cwd,
                                                          additionalDirectories: agent.additionalDirectories,
                                                          mcpServers: servers)
                updated.runtimeSessionID = result.sessionId
                // A conversation beginning again, so the briefing goes again: it
                // lived in the history this runtime has just told us it no longer has.
                needsBriefing.insert(agent.id)
            }
        } else {
            let result = try await session.newSession(cwd: agent.cwd,
                                                      additionalDirectories: agent.additionalDirectories,
                                                      mcpServers: servers)
            updated.runtimeSessionID = result.sessionId
            needsBriefing.insert(agent.id)
        }
        // Empty is not an answer, for either of them. A runtime that sends its options
        // or its commands as a `session/update` rather than on the `session/new` result
        // has none at this instant, and writing that over a record that already had some
        // leaves the row under the prompt with nothing to draw, and the slash list empty,
        // until the notification lands — or for good, where a runtime advertises them
        // once and a picked-up session never says it again.
        // `ACPSession.setOption` already guards the same assignment the same way.
        let refreshed = await session.options
        if !refreshed.isEmpty { updated.advertisedOptions = refreshed }
        let commands = await session.commands
        if !commands.isEmpty { updated.availableCommands = commands }
        changed(updated)
        await session.apply(updated.startOptions)
        live[agent.id] = session
        listen(to: session, agentID: agent.id)
        await prepareServing(session, agentID: agent.id)
        return session
    }

    // MARK: The turn itself

    func beginTurn(agentID: UUID, text: String, blocks: [ContentBlock]? = nil,
                   session: ACPSession) async {
        let blocks = blocks ?? [.text(text)]
        // Whatever was suggested has been answered now, by being taken or by being
        // typed past. Either way it is about the turn before this one.
        clearSuggestions(for: agentID)
        // The text is kept beside the blocks so the record reads the way it always has.
        await record(.userMessage(text, blocks: blocks.count > 1 ? blocks : []), for: agentID)
        await move(agentID, on: .promptSent)
        turnTasks[agentID]?.cancel()
        // The words of ours, sent with the first prompt of a conversation and not
        // again. They stay in the runtime's own history from there, and that history is
        // what a runtime replays when the session is picked back up, so sending them
        // every turn would be paying twice for something already said. The record
        // above is the user's words alone either way: the transcript says what was
        // said, not what we added to it.
        var outgoing = blocks
        if needsBriefing.remove(agentID) != nil {
            outgoing.append(.text(Briefing.text))
        }
        turnTasks[agentID] = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await session.prompt(outgoing)
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

    /// Hand a runtime back.
    ///
    /// The order is the whole of it. `forget` takes the listener out of the table
    /// without cancelling it, so whatever the runtime said in the last instant is
    /// still in hand. `end` closes the session, and closing is what ends the event
    /// stream. Only then is the listener waited on: by that point it has a finite
    /// buffer to get through and no more can arrive, so this returns once the record
    /// is complete and not before. A window reading the transcript the moment an
    /// agent finishes sees all of it.
    ///
    /// Waiting here cannot deadlock. The listener calls back into this actor, and an
    /// actor awaiting is an actor free to run something else; and it cannot outlast
    /// `end`, which this already waited for.
    func releaseRuntime(for agentID: UUID) async {
        guard let session = live[agentID] else { return }
        let draining = forget(agentID)
        await session.end(gracePeriod: .seconds(3))
        await draining?.value
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
        // Withdrawn from the pick-up queue before any `await`, which on an actor is
        // the whole of the lock. Without this, stopping a chat waiting to come back
        // does nothing anybody can see — it holds no runtime and has no turn in
        // flight — and the resume loop starts it seconds later. `interrupted` alone
        // stops the pick-up, but `resuming` must go too or the daemon stays alive for
        // a chat nobody is bringing back.
        let hadPickUpPending = interrupted.removeValue(forKey: agentID) != nil
            || resuming.contains(agentID)
        leaveTheQueue(agentID)
        for (id, pending) in pendingPermissions where pending.agentID == agentID {
            if let session = live[agentID] {
                await session.answerPermission(id: pending.request.id, optionID: nil)
            }
            pendingPermissions.removeValue(forKey: id)
            broadcast(DaemonAPI.Notification.agentPermission,
                      DaemonAPI.PermissionNotification(agentID: agentID, request: nil))
        }
        for (id, pending) in elicitations where pending.agentID == agentID {
            if let session = live[agentID] {
                await session.answerElicitation(id: pending.request.id, outcome: .cancel)
            }
            elicitations.removeValue(forKey: id)
            broadcast(DaemonAPI.Notification.agentElicitation,
                      DaemonAPI.ElicitationNotification(agentID: agentID, requestID: id, request: nil))
        }
        if let session = live[agentID] { await session.cancel() }
        turnTasks.removeValue(forKey: agentID)?.cancel()
        if agent.state.holdsRuntime {
            await move(agentID, on: .stoppedByUser, endedReason: .cancelled)
        }
        // Only when there was in fact a pick-up to withdraw. An ordinary stop should
        // not gain a line about something that was never going to happen.
        if hadPickUpPending {
            await record(.runtimeNote("You stopped this agent before it was picked back up."),
                         for: agentID)
            DaemonLog.shared.write("withdrew the pick-up for agent \(agentID): stopped first")
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
