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
    public func options(_ request: DaemonAPI.OptionsRequest,
                        connection: UUID? = nil) async throws -> DaemonAPI.OptionsResponse {
        let draftID = UUID()
        let pending = Task { [self] in
            try await freshSession(runtimeID: request.runtimeID, cwd: request.cwd,
                                   mcpServers: request.mcpServers)
        }
        drafts[draftID] = Draft(runtimeID: request.runtimeID, cwd: request.cwd,
                                mcpServers: request.mcpServers, pending: pending,
                                connection: connection)
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

    /// What this runtime last advertised for this folder, and nothing else.
    ///
    /// Starts no session and spawns no process, which is the whole of why it is not
    /// `agents/options`. A workflow attaches no MCP servers, so the key is built with
    /// an empty list. An empty answer is a real answer and is returned as one.
    public func rememberedOptions(_ request: DaemonAPI.RememberedOptionsRequest) -> [ConfigOption] {
        let key = OptionCache.key(runtimeID: request.runtimeID, cwd: request.cwd, mcpServers: [])
        return rememberedOptions(for: key)?.options ?? []
    }

    func remember(_ entry: OptionCache.Entry, for key: String) {
        guard entry.isWorthKeeping else { return }
        if rememberedOptions == nil { rememberedOptions = optionCache.load() }
        rememberedOptions?[key] = entry
        try? optionCache.save(rememberedOptions ?? [:])
    }

    /// A start from a window or a phone.
    ///
    /// With a request id, a start sent again is the same start: one still under way is
    /// waited on, and one that finished is found by the id on its record. A refused
    /// start leaves nothing behind under the id, so trying again once the reason has
    /// gone starts it (029).
    public func start(_ request: DaemonAPI.StartRequest) async throws -> UUID {
        let id = try await startOnce(request)
        // The person's choice, so remembered for the next one on any device. Only
        // here: an agent started by another agent was not the person choosing.
        if let agent = agents[id] {
            rememberMode(in: request.startOptions.values, runtimeID: agent.runtimeID,
                         options: agent.advertisedOptions)
        }
        return id
    }

    private func startOnce(_ request: DaemonAPI.StartRequest) async throws -> UUID {
        guard let requestID = request.requestID else {
            return try await start(request, startedBy: nil)
        }
        if let underWay = startsByRequest[requestID] { return try await underWay.value }
        if let made = agents.values.first(where: { $0.startRequestID == requestID }) { return made.id }
        let starting = Task { try await self.start(request, startedBy: nil) }
        startsByRequest[requestID] = starting
        defer { startsByRequest[requestID] = nil }
        return try await starting.value
    }

    // MARK: The mode each runtime was last started in (029)

    public func rememberedModes() -> DaemonAPI.RememberedModes {
        modeStore.remembered()
    }

    /// A window's memory from before the daemon kept one. Fills gaps only.
    public func importModes(_ request: DaemonAPI.ModesImportRequest) -> DaemonAPI.RememberedModes {
        if (try? modeStore.importing(request.modes)) == true { tellModes() }
        return modeStore.remembered()
    }

    /// Remember the mode among these values, if one of them is this runtime's mode.
    func rememberMode(in values: [String: JSONValue], runtimeID: String, options: [ConfigOption]) {
        guard let mode = ModeMemory.modeOption(in: options), let value = values[mode.id] else { return }
        if (try? modeStore.remember(value, for: runtimeID)) == true { tellModes() }
    }

    private func tellModes() {
        broadcast(DaemonAPI.Notification.modesChanged, modeStore.remembered())
    }

    /// Let go of a draft that is not going to be started. Not there is not an error:
    /// gone is what was asked for, and a phone discarding on its way out cannot know
    /// whether the start it raced got there first (029).
    public func discardDraft(_ request: DaemonAPI.DiscardDraftRequest) async {
        guard let draft = drafts.removeValue(forKey: request.draftID) else { return }
        await endDraft(draft)
    }

    /// A connection went. Its drafts are let go once the grace period passes, unless
    /// something has used or discarded them by then (029).
    func orphanDrafts(connection: UUID) {
        let when = now()
        for (id, draft) in drafts where draft.connection == connection && draft.orphanedAt == nil {
            drafts[id]?.orphanedAt = when
            Task { [self, grace = draftGracePeriod] in
                try? await Task.sleep(for: grace)
                await self.endOrphan(id, orphanedAt: when)
            }
        }
    }

    private func endOrphan(_ id: UUID, orphanedAt: Date) async {
        guard let draft = drafts[id], draft.orphanedAt == orphanedAt else { return }
        drafts.removeValue(forKey: id)
        await endDraft(draft)
    }

    /// A start, made on behalf of another agent when `starter` is set (028). Not on
    /// the wire: nothing a window or a phone sends can say an agent started this one,
    /// so nothing but `startHelper` can make an agent the tools are kept from.
    ///
    /// `chainDepth` is how deep a workflow fire this agent causes would be, read off
    /// the starter before any of the awaits here — see `Agent.chainDepth`.
    func start(_ request: DaemonAPI.StartRequest, startedBy starter: UUID?,
               chainDepth: Int? = nil) async throws -> UUID {
        // Before the session is made. Refusing after spawning a runtime costs a
        // process for a turn that was never going to run. A new agent has no queue
        // to wait on, which is why this is a refusal where a prompt is a hold — and
        // it names the limit, because a silent refusal is the one thing forbidden.
        let limits = limitStore.load()
        if limits.isDayLimitReached(spentToday: spendLedger.total(on: now())) {
            let spent = Cost.total(of: spendLedger.total(on: now())) ?? "nothing"
            let ceiling = limits.daily
                .map { $0.amount.formatted(.currency(code: $0.currency)) } ?? "the day's limit"
            throw JSONRPCError(
                code: DaemonAPI.Failure.dayLimitReached,
                message: "Today has cost \(spent), which reaches the \(ceiling) you allowed for a day. "
                    + "Nothing new starts until the day rolls over, or until you raise the limit.")
        }
        // A zero is a limit every agent has reached before it spends anything. The
        // gate in `sendNextQueued` cannot see that — a new agent has measured nothing
        // yet — so it is said here, where the start is still only a request.
        if let perAgent = limits.perAgent, perAgent.amount <= 0 {
            throw JSONRPCError(
                code: DaemonAPI.Failure.agentLimitReached,
                message: "The limit for each agent is set to nothing, so no agent can start. "
                    + "Raise it to start this one.")
        }
        // The worktree first, before any runtime: a start that cannot have the folder it
        // asked for starts nothing (FR-013). From here on `cwd` is where the agent
        // works, which for a new worktree is a folder no draft was made in, so the
        // draft below is let go and the runtime starts inside the worktree (R2).
        var placed: (cwd: URL, worktree: AgentWorktree)?
        if let choice = request.worktree {
            placed = try await prepareWorktree(choice, from: request.cwd, prompt: request.prompt)
        }
        let cwd = placed?.cwd ?? request.cwd
        let session: ACPSession
        let sessionID: String
        let appToken: String
        // A draft is only usable if it was made with the servers this start names.
        // They are read once, when the session is made, so reusing a session that
        // never heard about a server would attach it in name only.
        let draft = request.draftID.flatMap { drafts.removeValue(forKey: $0) }
        let usable = draft.flatMap { $0.runtimeID == request.runtimeID && $0.cwd == cwd
                                     && $0.mcpServers == request.mcpServers
                                     && $0.managesAgents == (starter == nil) ? $0 : nil }
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
            let made = try await freshSession(runtimeID: request.runtimeID, cwd: cwd,
                                              mcpServers: request.mcpServers,
                                              managesAgents: starter == nil)
            session = made.session
            sessionID = made.sessionID
            appToken = made.appToken
        }

        var agent = Agent(runtimeID: request.runtimeID,
                          cwd: cwd,
                          title: Agent.fallbackTitle(from: request.prompt),
                          runtimeSessionID: sessionID,
                          startOptions: request.startOptions,
                          advertisedOptions: await session.options,
                          availableCommands: await session.commands,
                          additionalDirectories: request.additionalDirectories,
                          mcpServers: request.mcpServers,
                          // On the queue from the agent's first moment, not held in
                          // this call. It is the only copy: a daemon killed between
                          // the save below and `beginTurn` would otherwise lose what
                          // the person typed entirely — only its first eighty
                          // characters survive, as the title — and the next daemon
                          // would pick the agent up and spend a turn asking it to
                          // work with nothing to work on.
                          queuedPrompts: [QueuedPrompt(text: request.prompt,
                                                       attachments: request.attachments)],
                          // On the record from the first save, so a daemon killed
                          // before the next one never finds this agent looking like the
                          // person's — with the tools, and holding no place.
                          startedByAgent: starter,
                          chainDepth: chainDepth,
                          worktree: placed?.worktree,
                          startRequestID: request.requestID)
        // Saved before it is known to the daemon, so a save that fails leaves nothing
        // behind claiming to hold a runtime. `starting` answers true to `holdsRuntime`,
        // so an agent stranded in it by a failed write would keep `isHoldingAgents`
        // true for ever and the daemon could never exit.
        do {
            try await store.save(agent)
        } catch {
            await session.end(gracePeriod: .seconds(2))
            throw error
        }
        agents[agent.id] = agent
        live[agent.id] = session
        // Where its changes will be measured from (035), asked for beside the start
        // rather than inside it: a start waits for nothing it does not need, and git
        // answers in milliseconds where a runtime takes seconds to make its first edit.
        Task { [self] in await takeStartingPoint(for: agent.id, in: cwd) }
        // The runtime was given this token before the agent existed. Now it means
        // something, and until this line a call carrying it is refused.
        bindAppToken(appToken, to: agent.id)
        // The first line of its chat, before its first prompt: who started it (028).
        if let starter {
            await record(.runtimeNote("Started by \(starterName(starter))."), for: agent.id)
        }
        // Where it is working, when that is not the project folder (030).
        if let worktree = placed?.worktree {
            await record(.runtimeNote(Self.worktreeNote(worktree)), for: agent.id)
        }
        // The first prompt of the conversation is the one that carries the briefing.
        needsBriefing.insert(agent.id)
        listen(to: session, agentID: agent.id)
        await prepareServing(session, agentID: agent.id)

        await session.apply(request.startOptions)
        agent = agents[agent.id] ?? agent
        changed(agent)

        // Stopped while it was being made. `starting` answers true to `holdsRuntime`,
        // which is exactly what lets `stop` act on an agent whose first turn has not
        // begun — and by now it has already moved the record to `stopped`, cancelled
        // what was queued and let the runtime go. Beginning a turn on top of that
        // would restart an agent the person has just stopped.
        //
        // Every `await` above this line is a window for it: `prepareServing`,
        // `session.apply`, and the two before them.
        guard var made = agents[agent.id], made.state == AgentState.starting,
              let first = made.queuedPrompts.first
        else { return agent.id }

        // Off the queue as its turn begins, exactly as `sendNextQueued` does it. It
        // cannot go through that function: `starting` answers true to
        // `hasTurnInFlight` — which is what makes a *second* prompt queue rather than
        // race (FR-004) — and that same answer would make `sendNextQueued` decline to
        // send the first.
        made.queuedPrompts.removeFirst()
        changed(made)
        await beginTurn(agentID: agent.id, text: first.text,
                        blocks: first.blocks, session: session)
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
    ///
    /// Internal rather than private because the workflow start path has to make a
    /// session before there is an agent, so that it can refuse a setting the runtime
    /// will not take without an agent ever existing to be refused on.
    func freshSession(runtimeID: String, cwd: URL,
                              mcpServers: [MCPServer] = [],
                              managesAgents: Bool = true) async throws -> MadeSession {
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
        var launched: ACPSession?
        do {
            let session = try launcher.launch(runtime: runtime, path: path, cwd: cwd)
            launched = session
            let handshake = try await session.initialize()
            // Recorded here rather than after the session is made, because the reason
            // to have it is the case where making the session fails: what comes back
            // then is "needs signing in", and the ways to sign in are in the handshake.
            noteAccount(runtimeID: runtimeID, from: handshake)
            let token = mintAppToken()
            let result = try await session.newSession(cwd: cwd,
                                                      mcpServers: mcpServers + [appServer(token: token, managesAgents: managesAgents)],
                                                      meta: ToolPolicyCatalog.policy(for: runtimeID).sessionMeta)
            return MadeSession(session: session, sessionID: result.sessionId,
                               runtime: runtime, appToken: token)
        } catch {
            // A runtime that would not make a session is still a running process.
            await launched?.end(gracePeriod: .seconds(1))
            throw startFailure(error, runtime: runtime, runtimeID: runtimeID)
        }
    }

    /// What a runtime that would not make a session is said to have done.
    private func startFailure(_ error: Error, runtime: Runtime, runtimeID: String) -> Error {
        switch error {
        case let error as JSONRPCError where error.isAuthRequired:
            markNeedsSignIn(runtimeID: runtimeID)
            // Not a fault. The runtime is there and needs signing in, which is
            // something the app can show and offer to fix.
            return signInNeeded(runtime: runtime, because: error.message)
        case ACPSessionError.needsSignIn:
            markNeedsSignIn(runtimeID: runtimeID)
            return signInNeeded(runtime: runtime, because: "it is not signed in")
        case ACPSessionError.unsupportedProtocolVersion(let version):
            return JSONRPCError(code: DaemonAPI.Failure.wrongProtocolVersion,
                                message: "\(runtime.name) speaks protocol version \(version), and this app speaks \(ACP.protocolVersion).")
        case let error as JSONRPCError:
            return JSONRPCError(code: DaemonAPI.Failure.runtimeWillNotStart,
                                message: "\(runtime.name) would not start a session: \(error.message)")
        default:
            return JSONRPCError(code: DaemonAPI.Failure.runtimeWillNotStart,
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
        var queued = QueuedPrompt(text: request.text, attachments: request.attachments,
                                  from: request.from)
        // The person's prompt takes the turn, and with it the agent's wait (042 FR-013).
        // The agent is told in the same prompt, before the person's words and not in
        // their bubble, so it can wait again if it still needs to.
        if request.from == .person, let ended = endWait(request.agentID, by: .prompt) {
            queued.preface = EventWords.cancelledByPrompt(ended)
            agent = agents[request.agentID] ?? agent
        }
        agent.queuedPrompts.insert(queued, at: first ? 0 : agent.queuedPrompts.endIndex)
        // The person moving the work on is what settles the turn before it. What the
        // agent said about that turn is now history, and so is any claim on the one
        // question this app will ask about a silence — they have superseded it.
        //
        // Only theirs. The app's own question clears neither: there is nothing there to
        // clear, and not clearing is how the two are told apart at all (FR-006, FR-023).
        if request.from == .person {
            agent.report = nil
            agent.outcomeAsked = false
        }
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

    /// Files under this agent's folders worth offering for what follows an `@` (033).
    ///
    /// The Mac's window walks the disk itself; a phone cannot, so it asks here, and the
    /// walk is the same capped one. Off the actor, because even capped it is thousands
    /// of stat calls, and nothing else the daemon does should wait on it.
    public func fileMentions(_ request: DaemonAPI.FileMentionRequest) async throws -> [DaemonAPI.FileMentionDTO] {
        guard let agent = agents[request.agentID] else {
            throw JSONRPCError(code: DaemonAPI.Failure.noSuchAgent, message: "That agent is not here.")
        }
        let term = request.term
        guard !term.isEmpty else { return [] }
        let folders = [agent.cwd] + agent.additionalDirectories
        let found = await Task.detached(priority: .userInitiated) {
            FileMention.matching(term, in: folders)
        }.value
        return found.map {
            DaemonAPI.FileMentionDTO(path: $0.url.path(percentEncoded: false), relativePath: $0.relativePath)
        }
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
        // The two limits, in the one funnel every turn begins through: a person
        // typing, a queued prompt draining behind a finished turn, a workflow's
        // prompt, and a restart pick-up all arrive here. Both return without
        // removing anything from the queue, which is this function's existing
        // promise — the words stay exactly where they were, and go when the day
        // rolls over or the reader raises the limit.
        //
        // Neither is silent. A prompt that goes nowhere without a word said is the
        // failure this whole feature is most able to produce, so each says which
        // limit stopped it — once per hold, so an agent at its limit does not fill
        // its own transcript saying so on every drain attempt.
        let limits = limitStore.load()
        if agent.isAtCostLimit(under: limits) {
            await holdForCostLimit(agentID)
            return
        }
        if isDayLimitReached(under: limits) {
            if held.insert(agentID).inserted {
                await record(.runtimeNote(
                    "What you sent is waiting: the day's spending limit has been reached. "
                    + "It will go when the day rolls over, or when you raise the limit."),
                             for: agentID)
            }
            return
        }
        held.remove(agentID)
        // Claimed before the runtime is started, because starting one is a long await
        // and the two callers of this can both arrive inside it: the user typing as a
        // turn ends, and that turn draining the queue behind them. Nothing else here
        // says "already going" until `beginTurn` sets the task, and by then the same
        // words have gone to two runtimes. The guard above is checked and this is set
        // without an await between them, which on an actor is the whole of the lock.
        sending.insert(agentID)
        defer { sending.remove(agentID) }
        let stopsBefore = stops[agentID, default: 0]
        let session = try await liveSession(for: agent)
        // Stopped or archived while the runtime was starting. `stop` found nothing
        // to cancel then — no runtime yet, no turn — so this is where it is heard:
        // the runtime goes back and the words stay queued, as stop promises.
        guard stops[agentID, default: 0] == stopsBefore else {
            await releaseRuntime(for: agentID)
            return
        }
        guard var agent = agents[agentID],
              let index = agent.queuedPrompts.firstIndex(where: { $0.id == next.id }) else { return }
        agent.queuedPrompts.remove(at: index)
        changed(agent)
        await beginTurn(agentID: agentID, text: next.text, blocks: next.blocks,
                        from: next.from, session: session, unlessStoppedSince: stopsBefore,
                        requeue: next, preface: next.preface)
    }

    /// Whatever is waiting, now that a turn has ended of its own accord.
    ///
    /// Not after the user stopped it: stop means stop, and the queue stays put for
    /// them to send or throw away themselves.
    func drainQueue(after agentID: UUID) async {
        // Nor after the agent that started it stopped it (028): that is a stop too.
        guard agents[agentID]?.endedReason != .cancelled,
              agents[agentID]?.endedReason != .stoppedByAgent else { return }
        // A limit is not a failure to send. `sendNextQueued` holds the words and
        // says which limit did it, so nothing extra belongs here — a second copy of
        // that decision is a second chance for the two to drift.
        do {
            try await sendNextQueued(to: agentID)
        } catch {
            await record(.runtimeNote("Could not send what you queued: \(reason(error)) It is still waiting."),
                         for: agentID)
        }
    }

    // MARK: Money

    /// Whether the day's limit is reached, as of what has been banked.
    ///
    /// One global fact rather than a per-agent one: every agent is affected
    /// identically, so there is one number to compare and nothing is marked.
    func isDayLimitReached(under limits: CostLimits? = nil) -> Bool {
        let limits = limits ?? limitStore.load()
        return limits.isDayLimitReached(spentToday: spendLedger.total(on: now()))
    }

    /// The whole truth about money as it stands, for a broadcast or a reply.
    func currentCostState() -> DaemonAPI.CostState {
        DaemonAPI.CostState(limits: limitStore.load(),
                            today: spendLedger.total(on: now()),
                            day: SpendLedger.stamp(for: now()))
    }

    /// Always after the ledger is written, never before. A window is never told about
    /// money the daemon has not yet recorded.
    func broadcastCostState() {
        broadcast(DaemonAPI.Notification.costChanged, currentCostState())
    }

    /// Bank a cost quoted on a **usage update**, into the agent and into the day.
    ///
    /// Not for the cost on a turn's own reply, which is a different fact: that one is
    /// what the turn cost and is simply added, in `finishTurn`. This one is a
    /// **running total for the runtime's session** — the SDK documents
    /// `total_cost_usd` as "cumulative across turns … read the latest result rather
    /// than summing across results" — so what is banked is its increase over the last
    /// reading. Two cases, and only two:
    ///
    /// - The reading went up. The difference is new spend. The ordinary case.
    /// - The reading went **down**. The session started over — a resume, or a
    ///   `/clear`, both of which the SDK documents as resetting the running total —
    ///   so the whole of the new reading is new spend on top of what the agent had
    ///   already cost. Never a correction downwards: money already spent stays spent,
    ///   and an agent's total must never go backwards under a reader who is watching
    ///   it against a limit.
    ///
    /// Equal readings bank nothing, which is what makes this safe to call on every
    /// one of the several usage updates a turn sends.
    ///
    /// `reader` is the session that quoted it: each process's running total is its own,
    /// and the next process counts from nothing.
    func bank(_ cost: Cost, into agent: inout Agent, readBy reader: UUID) {
        let previous = costReadings[reader]?[cost.currency] ?? 0
        let added = cost.amount >= previous ? cost.amount - previous : cost.amount
        costReadings[reader, default: [:]][cost.currency] = cost.amount
        guard added > 0 else { return }
        // Per currency. Adding two currencies would be a number nobody could check.
        agent.costToDate[cost.currency] = (agent.costToDate[cost.currency] ?? 0) + added
        // The ledger before the windows: a daemon killed between here and the next
        // broadcast comes back having counted the money rather than having forgotten
        // it. It is also the only copy that survives the agent being archived.
        spendLedger.add(Cost(amount: added, currency: cost.currency), on: now())
    }

    /// Send what is waiting to every agent that has something waiting.
    ///
    /// What the day rolling over does, and what raising the daily limit does. A held
    /// agent is an ordinary settled agent with an undrained queue, so this is the
    /// whole of "it becomes promptable again where it stands".
    func drainEverythingHolding() async {
        held.removeAll()
        for (id, agent) in agents where !agent.queuedPrompts.isEmpty {
            // Put away is put away. A held prompt on an agent archived since would
            // otherwise take it out of the archive at midnight and spend money on it.
            // `held` alone is not the test: it is memory, and a restart forgets it.
            guard agent.state != .archived else { continue }
            await drainQueue(after: id)
        }
    }

    // MARK: The reader's limits

    public func costState() async -> DaemonAPI.CostState { currentCostState() }

    public func setLimits(_ request: DaemonAPI.SetLimitsRequest) async -> DaemonAPI.CostState {
        var limits = limitStore.load()
        let dayWasReached = isDayLimitReached(under: limits)
        // Absent leaves it alone; present-and-null clears it. A zero is a limit and
        // is never a way to turn one off.
        if case .some(let value) = request.perAgent { limits.perAgent = value }
        if case .some(let value) = request.daily { limits.daily = value }
        // Written before the reply returns and before anything is broadcast. A limit
        // lower than what is already spent is allowed and is not an error: the reply
        // carries the new state, from which the caller can see it is already reached
        // and say so at the moment it is set.
        try? limitStore.save(limits)
        broadcastCostState()
        // Raising the daily limit takes effect now, without a restart.
        if dayWasReached && !isDayLimitReached(under: limits) {
            await drainEverythingHolding()
        }
        return currentCostState()
    }

    /// Letting one agent carry on past the per-agent limit, or giving it a tighter
    /// ceiling of its own. Exactly one agent; no other agent and neither app-wide
    /// limit is touched.
    public func setCeiling(_ request: DaemonAPI.SetCeilingRequest) async throws -> Agent {
        guard var agent = agents[request.agentID] else {
            throw JSONRPCError(code: DaemonAPI.Failure.noSuchAgent, message: "That agent is not here.")
        }
        agent.costCeiling = request.ceiling
        changed(agent)
        // Deliberately does not send a prompt. Raising a ceiling makes an agent
        // promptable again; continuing is the reader's second, deliberate act.
        held.remove(request.agentID)
        return agents[request.agentID] ?? agent
    }

    func reason(_ error: any Error) -> String {
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
        // Its worktree gone is said, not worked around: starting it in the project
        // folder instead would put its work somewhere nobody asked for (FR-017).
        if let worktree = agent.worktree, !Self.isDirectory(agent.cwd) {
            throw JSONRPCError(code: DaemonAPI.Failure.worktreeMissing,
                               message: "The worktree \(worktree.name) is gone, so this agent cannot be picked up where it was.")
        }
        await record(.runtimeNote(RuntimeNote.starting(runtime.name)), for: agent.id)
        let session = try launcher.launch(runtime: runtime, path: path, cwd: agent.cwd)
        do {
            return try await connect(session, runtime: runtime, for: agent)
        } catch {
            // Nothing holds a session that never made it into `live`, and a process
            // left behind here is a runtime nobody will ever end.
            dropAppTokens(for: agent.id)
            await session.end(gracePeriod: .seconds(1))
            throw error
        }
    }

    private func connect(_ session: ACPSession, runtime: Runtime, for agent: Agent) async throws -> ACPSession {
        _ = try await session.initialize()

        // A new process is a new MCP server, so a new token. The old one stopped
        // working when the last process died.
        let token = mintAppToken()
        // Picked back up as what it was: an agent another agent started still has no
        // tools for starting agents (028).
        let servers = agent.mcpServers + [appServer(token: token, managesAgents: agent.startedByAgent == nil)]
        bindAppToken(token, to: agent.id)

        // The same scoping a new conversation gets, so an agent picked back up is not
        // quietly wider than one started this minute (FR-012).
        let meta = ToolPolicyCatalog.policy(for: agent.runtimeID).sessionMeta

        // Only what this start learns is carried across the awaits below. The rest of
        // the record is read again at the end: a start takes seconds, and a prompt
        // queued, withdrawn or archived in them is newer than the copy we began with.
        var newSessionID: String?
        if let sessionID = agent.runtimeSessionID {
            do {
                try await session.continueSession(id: sessionID, cwd: agent.cwd,
                                                  additionalDirectories: agent.additionalDirectories,
                                                  mcpServers: servers,
                                                  meta: meta)
                await record(.runtimeNote(RuntimeNote.pickedBackUp), for: agent.id)
            } catch {
                // The runtime no longer has it. The agent is not lost: it carries on as
                // the same agent, with our transcript, in a new runtime session.
                await record(.runtimeNote("\(runtime.name) no longer has this conversation. Carrying on in a new one; everything above is kept."),
                             for: agent.id)
                let result = try await session.newSession(cwd: agent.cwd,
                                                          additionalDirectories: agent.additionalDirectories,
                                                          mcpServers: servers,
                                                          meta: meta)
                newSessionID = result.sessionId
                // A conversation beginning again, so the briefing goes again: it
                // lived in the history this runtime has just told us it no longer has.
                needsBriefing.insert(agent.id)
            }
        } else {
            let result = try await session.newSession(cwd: agent.cwd,
                                                      additionalDirectories: agent.additionalDirectories,
                                                      mcpServers: servers,
                                                      meta: meta)
            newSessionID = result.sessionId
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
        let commands = await session.commands
        guard var updated = agents[agent.id] else {
            throw JSONRPCError(code: DaemonAPI.Failure.noSuchAgent, message: "That agent is not here.")
        }
        if let newSessionID { updated.runtimeSessionID = newSessionID }
        if !refreshed.isEmpty { updated.advertisedOptions = refreshed }
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
                   from: PromptOrigin = .person, session: ACPSession,
                   unlessStoppedSince stopsBefore: Int? = nil, requeue: QueuedPrompt? = nil,
                   preface: String? = nil) async {
        let blocks = blocks ?? [.text(text)]
        // Whatever was suggested has been answered now, by being taken or by being
        // typed past. Either way it is about the turn before this one.
        //
        // Only by them. The app's own question is not an answer to a suggestion, and
        // taking the chips away would lose the person something they never acted on
        // over a turn they did not ask for (FR-031).
        if from == .person { clearSuggestions(for: agentID) }
        // The text is kept beside the blocks so the record reads the way it always has.
        await record(.userMessage(text, blocks: blocks.count > 1 ? blocks : [], from: from),
                     for: agentID)
        // Stopped or archived while that was written. The move below would otherwise
        // take an archived agent straight back out of the archive — the app's own
        // question to a silent agent did, and started it in a worktree the archive had
        // just removed. The app's words go; a person's go back on the queue, as a stop
        // promises.
        if let stopsBefore, stops[agentID, default: 0] != stopsBefore {
            if from == .person, let requeue, var agent = agents[agentID] {
                agent.queuedPrompts.insert(requeue, at: 0)
                changed(agent)
            }
            await releaseRuntime(for: agentID)
            return
        }
        // One moment reached from two directions: the first turn of an agent that is
        // still `starting`, and an ordinary prompt to a settled one. They are two
        // events rather than one because that is what lets the table refuse
        // `(.starting, .promptSent)` — a prompt arriving mid-start has to queue.
        await move(agentID, on: agents[agentID]?.state == .starting ? .turnBegun : .promptSent)
        turnTasks[agentID]?.cancel()
        // The words of ours, sent with the first prompt of a conversation and not
        // again. They stay in the runtime's own history from there, and that history is
        // what a runtime replays when the session is picked back up, so sending them
        // every turn would be paying twice for something already said. The record
        // above is the user's words alone either way: the transcript says what was
        // said, not what we added to it.
        var outgoing = blocks
        // What the app owes the agent about this prompt, and only the agent (042).
        if let preface { outgoing.insert(.text(preface), at: 0) }
        // The runtime is read first on purpose: an agent that has somehow gone keeps its
        // place in the queue rather than having the briefing quietly spent on nobody.
        if let runtimeID = agents[agentID]?.runtimeID, needsBriefing.remove(agentID) != nil {
            // An agent another agent started hears nothing about starting agents: it
            // was not given the tools (028).
            let managesAgents = agents[agentID]?.startedByAgent == nil
            outgoing.append(.text(Briefing.text(for: ToolPolicyCatalog.policy(for: runtimeID),
                                                managesAgents: managesAgents)))
        }
        // What the person changed on a live page since this agent last took a turn
        // (022 FR-016). Told once, here, after their words and in the briefing's
        // slot, and then forgotten: the edit itself is in the file. Whoever sent the
        // prompt — the person, a workflow — the agent needs to know either way.
        if let edits = artifactEdits.removeValue(forKey: agentID),
           let note = Briefing.artifactEdited(edits.map {
               Briefing.ArtifactEdit(path: $0.path, lines: $0.lines, text: $0.text)
           }) {
            outgoing.append(.text(note))
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
        // Read before anything is awaited, so a stop in any of the waits below is seen.
        let stopsBefore = stops[agentID, default: 0]
        // Whether this turn was the one that crossed the per-agent ceiling. Decided
        // here because banking is what makes a limit true, and acted on below rather
        // than now because the turn is the unit: it finishes, whole, first.
        var crossedItsLimit = false
        if let usage = result.usage {
            await record(.usageRecorded(usage), for: agentID)
            if var agent = agents[agentID] {
                agent.lastTurnUsage = usage
                // A cost quoted *here* is what this one turn cost, so it is added.
                // A cost quoted on the usage update is a running total for the
                // session, so that one is banked by its increase — see `bank`. Two
                // different facts with the same name, which is the whole of why this
                // feature read "Not measured" for a month.
                //
                // `claude-agent-acp` never quotes a cost here: it builds this reply
                // from `sessionUsage()`, which has no cost field. This is the door
                // for the runtimes that do.
                if let cost = usage.cost {
                    // Per currency. Adding two currencies would be a number nobody
                    // could check.
                    agent.costToDate[cost.currency] = (agent.costToDate[cost.currency] ?? 0) + cost.amount
                    // The record before the windows: a daemon killed between these
                    // two lines comes back having counted the money rather than
                    // having forgotten it.
                    spendLedger.add(cost, on: now())
                }
                let limits = limitStore.load()
                crossedItsLimit = agent.isAtCostLimit(under: limits)
                changed(agent)
                if usage.cost != nil { broadcastCostState() }
            }
        }
        var reason: EndedReason
        if let known = result.reason {
            reason = known
        } else {
            // Written down as given. The ending line says only that the reason is
            // one we do not know; the wire's own word for it is the one thing worth
            // having when that ending is reported, and one word is not a dump.
            await record(.runtimeNote("The runtime ended the turn with a stop reason we do not know: \(result.rawStopReason ?? "none")."),
                         for: agentID)
            reason = .unrecognised
        }
        if crossedItsLimit {
            // The limit is what this agent stopped for, whatever the turn's own
            // reason was. Said in the app's voice and with the figure it actually
            // spent — which may be over the limit, because a turn is never cut short
            // and a figure clamped to the limit would be a lie.
            reason = .costLimit
            if let agent = agents[agentID] {
                let limits = limitStore.load()
                let spent = Cost.total(of: agent.costToDate) ?? "nothing"
                let ceiling = agent.ceiling(under: limits)
                    .map { $0.amount.formatted(.currency(code: $0.currency)) } ?? "its limit"
                await record(.runtimeNote(
                    "Stopped: this agent has spent \(spent), which reaches the \(ceiling) limit you set. "
                    + "The turn it was in finished first, so nothing is half-done. "
                    + "Raise the limit, or let this one agent go on, and it will take a prompt again."),
                             for: agentID)
            }
        }
        await move(agentID, on: .turnEnded(reason))
        // A finished agent's process is let go: every runtime hands the session back,
        // so holding one open buys nothing and works against the daemon's exit rule.
        await releaseRuntime(for: agentID)
        // Stopped since this turn ended, while its runtime was being let go. `stop`
        // found nothing running and moved nothing, so this is where it is heard: no
        // question of the app's own, and what is queued stays queued, as stop promises.
        guard stops[agentID, default: 0] == stopsBefore else { return }
        // A turn that crossed its limit leaves its queue exactly where it is, whatever
        // the limit says by the time the runtime has gone. Letting the agent go on is
        // the reader's second act (FR-018), and a ceiling raised in the seconds the
        // release takes would otherwise have the drain below send the held words for
        // them.
        if crossedItsLimit {
            if agents[agentID]?.queuedPrompts.isEmpty == false { await holdForCostLimit(agentID) }
            return
        }
        // Ended blocked, with everything it named already over (039): carried on here,
        // after the runtime is let go, and never from inside `move`, where the release
        // still to come would take the new turn's runtime with it.
        await resumeIfCleared(agentID)
        await askForOutcomeIfSilent(agentID: agentID, reason: reason)
        await drainQueue(after: agentID)
    }

    /// Say, once per hold, that this agent's queue is waiting on its cost limit.
    func holdForCostLimit(_ agentID: UUID) async {
        guard held.insert(agentID).inserted else { return }
        await record(.runtimeNote(
            "What you sent is waiting: this agent has reached its cost limit. "
            + "Raise the limit, or let this one agent go on, and it will go."),
                     for: agentID)
    }

    /// A turn ended and said nothing about how it went. Ask, once.
    ///
    /// Most silences are an agent that simply forgot, and one question gets an answer
    /// out of most of them. A second would be an argument, and an unbounded number
    /// would let a runtime that will never call the tool double the cost of every turn
    /// it takes — so the flag goes up *before* the prompt is enqueued. The turn this
    /// question causes comes back through here, finds the flag already set, and stops.
    /// That is what makes the bound structural rather than a convention somebody has to
    /// keep.
    ///
    /// Nothing is owed after the fact. A daemon that restarts between the ending and
    /// this leaves `outcomeAsked` false on a record whose turn is long over, which is
    /// harmless: only a fresh `.endTurn` opens the gate.
    func askForOutcomeIfSilent(agentID: UUID, reason: EndedReason) async {
        guard willAskForOutcome(agentID: agentID, reason: reason),
              var agent = agents[agentID] else { return }
        agent.outcomeAsked = true
        changed(agent)
        // Through the ordinary path, so it starts the runtime, is recorded, and has
        // what it costs counted against the agent like any other turn (FR-024).
        try? await enqueue(DaemonAPI.PromptRequest(agentID: agentID, text: Self.askForOutcome,
                                                   from: .app), first: false)
    }

    /// Whether this ending is one the app is about to ask about.
    ///
    /// Asked twice, at two moments in the same ending: once by `move`, which holds the
    /// lifecycle workflows back so they fire on the ending that is accounted for rather
    /// than on both, and once by `askForOutcomeIfSilent`, which acts on it. The same
    /// five conditions either time, which is why they are here and not written out
    /// twice.
    ///
    /// An ending short keeps its own wording and is never asked about: this feature
    /// adds an account of the *work*, not a restatement of how the *turn* ended
    /// (FR-025). A prompt already waiting means they have moved the work on, and asking
    /// an agent to account for a turn they have superseded is noise (FR-023).
    func willAskForOutcome(agentID: UUID, reason: EndedReason?) -> Bool {
        guard reason == .endTurn, let agent = agents[agentID] else { return false }
        return agent.state == .finished
            && agent.report == nil
            && !agent.outcomeAsked
            && agent.queuedPrompts.isEmpty
    }

    /// The whole of what a silent agent is asked. Short, and closed: an agent invited
    /// to explain itself in prose would explain itself in prose, and prose is not an
    /// outcome.
    ///
    /// It names the one tool a fresh conversation was told about (023). An agent
    /// briefed with the older name answers by that name all the same, because the
    /// older names are accepted everywhere the new one is.
    ///
    /// It used to end "and say nothing else", and Opus 5.5 took that literally: after
    /// the call it still owes a reply, and the nothing it wrote was zero-width spaces —
    /// one, usually, and once twenty-two thousand of them. Nothing is said about what
    /// comes after the call now; the call is what is asked for.
    static let askForOutcome = """
        That turn ended without a report. Call \(AppTool.finishTurn) now with how it \
        actually went. If the work is done, that is done.
        """

    private func turnFailed(agentID: UUID, error: any Error) async {
        turnTasks.removeValue(forKey: agentID)
        // Before anything else is said, so the record reads: the question, that nobody
        // answered it, why the agent stopped, and that it did. And at all, which it was
        // not until 025: a turn that fails ahead of the process-exit event reaches here
        // first, releases the runtime, and the exit arm's own close never ran — leaving
        // the question pending, still asking on the Mac and the phone.
        await closeQuestionsOfAGoneRuntime(agentID)
        // A plain sentence on the page, and the error itself in the log. What the
        // transport threw is for whoever is debugging the runtime, not for the
        // person reading the conversation.
        let runtimeName = agents[agentID].flatMap { RuntimeCatalog.runtime(id: $0.runtimeID)?.name } ?? "The runtime"
        await record(.runtimeNote("\(runtimeName) stopped answering."), for: agentID)
        DaemonLog.shared.write("agent \(agentID): the runtime stopped answering: \(error)")
        await move(agentID, on: .processDied)
        await releaseRuntime(for: agentID)
        // Picking the agent back up is what any prompt does, so what was queued still
        // goes. A runtime that fell over is not a reason to lose what somebody typed.
        await drainQueue(after: agentID)
    }

    /// Close every question this agent has open, because the runtime that asked them has
    /// gone and none of them can be answered now.
    ///
    /// The one place for it, reached by both ways a runtime goes: its process exiting, and
    /// its turn failing — which can get there first and release the runtime before the
    /// exit is heard. A question kept past that would go on asking on the Mac and the
    /// phone for an agent that can no longer hear the answer, and refuse its next outcome
    /// report over a question it cannot see.
    ///
    /// Each says so in the conversation, once per question (025 US4). Without it the record
    /// reads "Asked: …" and then simply stops, and whether anybody answered is left to be
    /// worked out from an absence. Taken off the list before the line is written, so an
    /// answer arriving in the same moment finds it gone rather than closing it twice.
    func closeQuestionsOfAGoneRuntime(_ agentID: UUID) async {
        for (id, pending) in pendingPermissions where pending.agentID == agentID {
            pendingPermissions.removeValue(forKey: id)
            await record(.runtimeNote(RuntimeNote.questionWentUnanswered), for: agentID)
            broadcast(DaemonAPI.Notification.agentPermission,
                      DaemonAPI.PermissionNotification(agentID: agentID, request: nil))
        }
        for (id, pending) in elicitations where pending.agentID == agentID {
            elicitations.removeValue(forKey: id)
            await record(.runtimeNote(RuntimeNote.questionWentUnanswered), for: agentID)
            broadcast(DaemonAPI.Notification.agentElicitation,
                      DaemonAPI.ElicitationNotification(agentID: agentID, requestID: id, request: nil))
        }
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

    /// Who asked for a stop or an archive (028). The person, from a window or the
    /// phone, or the agent that started this one, through its own tools. Everything a
    /// stop does is the same either way; the ending and the line in the transcript say
    /// which.
    public enum StopCause: Sendable, Equatable {
        case person
        case agent(UUID)

        /// The agent that asked, when one did.
        public var starter: UUID? {
            if case .agent(let id) = self { return id }
            return nil
        }
    }

    public func stop(_ agentID: UUID, by cause: StopCause = .person) async throws {
        guard let agent = agents[agentID] else {
            throw JSONRPCError(code: DaemonAPI.Failure.noSuchAgent, message: "That agent is not here.")
        }
        // Withdrawn from the pick-up queue before any `await`, which on an actor is
        // the whole of the lock. Without this, stopping a chat waiting to come back
        // does nothing anybody can see — it holds no runtime and has no turn in
        // flight — and the resume loop starts it seconds later. `interrupted` alone
        // stops the pick-up, but `resuming` must go too or the daemon stays alive for
        // a chat nobody is bringing back.
        stops[agentID, default: 0] += 1
        let hadPickUpPending = interrupted.removeValue(forKey: agentID) != nil
            || resuming.contains(agentID)
        leaveTheQueue(agentID)
        // Every lease it holds given back and every line it is in left (036 FR-007),
        // before any `await`, so nothing is handed to it halfway through stopping.
        // Said at the end, once the stop itself is in the transcript.
        let leaseEvents = dropLeases(for: agentID, ending: .holderStopped)
        // Each open question is taken off the list before anything is awaited, then said
        // in the conversation to have gone unanswered, then refused to the runtime. In
        // that order: an answer arriving in the same moment finds it gone rather than
        // closing it a second time, and the line lands before anything the refusal sets
        // off — the runtime ending its turn, say — so the record reads as it happened.
        for (id, pending) in pendingPermissions where pending.agentID == agentID {
            pendingPermissions.removeValue(forKey: id)
            await record(.runtimeNote(RuntimeNote.questionWentUnanswered), for: agentID)
            if let session = live[agentID] {
                await session.answerPermission(id: pending.request.id, optionID: nil)
            }
            broadcast(DaemonAPI.Notification.agentPermission,
                      DaemonAPI.PermissionNotification(agentID: agentID, request: nil))
        }
        for (id, pending) in elicitations where pending.agentID == agentID {
            elicitations.removeValue(forKey: id)
            await record(.runtimeNote(RuntimeNote.questionWentUnanswered), for: agentID)
            if let session = live[agentID] {
                await session.answerElicitation(id: pending.request.id, outcome: .cancel)
            }
            broadcast(DaemonAPI.Notification.agentElicitation,
                      DaemonAPI.ElicitationNotification(agentID: agentID, requestID: id, request: nil))
        }
        if let session = live[agentID] { await session.cancel() }
        turnTasks.removeValue(forKey: agentID)?.cancel()
        // Re-read, rather than trusting the `agent` captured at the top of this
        // function: several `await`s have happened since, and the turn may have ended
        // under us. It used to be kept roughly in step by the `endedReason` pre-write
        // that stood here; that write is gone, because writing an ending before the
        // table has agreed to one is the thing FR-010 forbids.
        //
        // The table would refuse the call anyway — `.finished` and `.stopped` both
        // reject `.stoppedByUser` — so this is not what keeps the record right. It is
        // here so the code says what it means instead of leaning on a refusal to
        // undo a call it should not have made.
        // A blocked agent (039). Its block is dropped first, so nothing clearing in the
        // awaits below can resume it; and a finished one, which has no turn to cancel,
        // is stopped on the one event that takes a finished agent to stopped.
        let wasBlocked = agents[agentID]?.report?.isOpenBlock == true
        dropBlock(agentID)
        // And a wait on events (042): stopped is never started again for it.
        endWait(agentID, by: .stopped)
        if wasBlocked, agents[agentID]?.state == .finished {
            if case .agent(let starter) = cause {
                await record(.runtimeNote("\(starterName(starter)) stopped this agent."), for: agentID)
            }
            await move(agentID, on: cause == .person ? .stoppedWaitingByUser : .stoppedWaitingByAgent)
        }
        if agents[agentID]?.state.holdsRuntime == true {
            switch cause {
            case .person:
                await move(agentID, on: .stoppedByUser)
            case .agent(let starter):
                // Said before the ending lands, so the transcript reads in the order
                // it happened: who stopped it, then that it stopped.
                await record(.runtimeNote("\(starterName(starter)) stopped this agent."), for: agentID)
                await move(agentID, on: .stoppedByAgent)
            }
        }
        // Only when there was in fact a pick-up to withdraw. An ordinary stop should
        // not gain a line about something that was never going to happen.
        if hadPickUpPending {
            let who = cause.starter.map(starterName) ?? "You"
            await record(.runtimeNote("\(who) stopped this agent before it was picked back up."),
                         for: agentID)
            DaemonLog.shared.write("withdrew the pick-up for agent \(agentID): stopped first")
        }
        // Stop means stop. What was queued is kept rather than sent on: the user says
        // when it goes, and the window keeps showing them it is there.
        if !agent.queuedPrompts.isEmpty {
            let count = agent.queuedPrompts.count
            let because = cause == .person ? "because you stopped it" : "because it was stopped"
            await record(.runtimeNote(count == 1
                ? "The message you queued was not sent, \(because). It is still waiting."
                : "The \(count) messages you queued were not sent, \(because). They are still waiting."),
                         for: agentID)
        }
        await releaseRuntime(for: agentID)
        await settle(leaseEvents)
    }

    public func archive(_ agentID: UUID, by cause: StopCause = .person) async throws {
        guard let agent = agents[agentID] else {
            throw JSONRPCError(code: DaemonAPI.Failure.noSuchAgent, message: "That agent is not here.")
        }
        stops[agentID, default: 0] += 1
        // Archived is never resumed (FR-017): the block goes before anything is awaited,
        // and so does a wait on events (042).
        dropBlock(agentID)
        endWait(agentID, by: .archived)
        // Before the stop, which would give them back as "stopped": an archived
        // agent's transcript should say it let go because it was archived (036).
        let leaseEvents = dropLeases(for: agentID, ending: .holderArchived)
        if agent.state.holdsRuntime { try await stop(agentID, by: cause) }
        await settle(leaseEvents)
        switch cause {
        case .person:
            await move(agentID, on: .archivedByUser)
        case .agent(let starter):
            await record(.runtimeNote("\(starterName(starter)) archived this agent."), for: agentID)
            await move(agentID, on: .archivedByAgent)
        }
        await removeWorktreeIfDone(archiving: agentID)
    }

    /// What an agent that started others is called in their transcripts: its title
    /// as it is now, or a plain word when it has none or has gone.
    func starterName(_ starter: UUID) -> String {
        guard let title = agents[starter]?.title?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else { return "Another agent" }
        return "\u{201C}\(title)\u{201D}"
    }

    public func unarchive(_ agentID: UUID) async throws {
        guard agents[agentID] != nil else {
            throw JSONRPCError(code: DaemonAPI.Failure.noSuchAgent, message: "That agent is not here.")
        }
        await move(agentID, on: .unarchivedByUser)
    }

    // MARK: Parking (040)

    /// Put a chat down to come back to. A settled chat is parked now; one with a turn in
    /// flight is marked, and `move` parks it the moment that turn ends, so nothing is cut
    /// off (FR-006). The runtime, the transcript and the queue are not touched (FR-005).
    /// An archived chat, or one already so, is left as it is and nothing is said (FR-017).
    public func park(_ agentID: UUID) throws {
        guard var agent = agents[agentID] else {
            throw JSONRPCError(code: DaemonAPI.Failure.noSuchAgent, message: "That agent is not here.")
        }
        guard agent.state != .archived else { return }
        let inFlight = agent.state.hasTurnInFlight
        switch (agent.parking, inFlight) {
        case (.parked, _), (.whenTurnEnds, true): return
        case (_, true): agent.parking = .whenTurnEnds(since: now())
        case (_, false): agent.parking = .parked(at: now())
        }
        changed(agent)
        reconsider()
    }

    /// Pick a chat back up without saying anything to it: it goes back to the group its
    /// ending puts it in, or, mid-turn, ends where it would have (FR-008).
    public func unpark(_ agentID: UUID) throws {
        guard agents[agentID] != nil else {
            throw JSONRPCError(code: DaemonAPI.Failure.noSuchAgent, message: "That agent is not here.")
        }
        unparkQuietly(agentID)
    }

    /// Take the mark off, if there is one. Shared with the person's prompt.
    func unparkQuietly(_ agentID: UUID) {
        guard var agent = agents[agentID], agent.parking != nil else { return }
        agent.parking = nil
        changed(agent)
        reconsider()
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
            rememberMode(in: [request.optionID: request.value], runtimeID: agent.runtimeID,
                         options: agent.advertisedOptions)
            await record(.optionChanged(id: request.optionID, value: request.value), for: request.agentID)
            return []
        }
        let options = try await session.setOption(id: request.optionID, value: request.value)
        if var agent = agents[request.agentID] {
            agent.advertisedOptions = options
            agent.startOptions.values[request.optionID] = request.value
            changed(agent)
            // Changing a conversation's mode says what you want next time too, as it
            // always has on the Mac.
            rememberMode(in: [request.optionID: request.value], runtimeID: agent.runtimeID,
                         options: options)
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
        reconsider()
    }

    public func transcript(_ request: DaemonAPI.TranscriptRequest) async throws -> TranscriptPage {
        try await store.transcript(for: request.agentID, before: request.before, limit: request.limit)
    }
}
