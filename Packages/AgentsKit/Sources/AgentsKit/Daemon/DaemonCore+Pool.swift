import Foundation
import AgentsKitCore

/// Carrying a chat on when its runtime's allowance runs out (052).
///
/// The decisions are pure and in Core (`LimitRecognition`, `AllowanceState`). This file
/// applies them at the two places a turn ends: `finishTurn` and `turnFailed`.
extension DaemonCore {
    /// What the daemon remembers about the prompt a turn was sent, so a rate-limited
    /// turn can be sent again as it was, and a spent one can be carried on with.
    struct SentPrompt: Sendable {
        var text: String
        var blocks: [ContentBlock]
        var from: PromptOrigin
        var preface: String?
        /// What the agent had spent when the turn began, for the credit ledger.
        var costBefore: [String: Decimal]
    }

    // MARK: Entries and states

    /// The pool entry an agent's runtime is on. An agent that started outside the pool,
    /// or before there was one, is judged as its runtime's own sign-in: an allowance,
    /// except Gemini, which only ever runs on a key (046).
    func poolEntry(for agent: Agent) -> PoolEntry {
        if let entry = pool.entry(agent.poolEntryID), entry.runtimeID == agent.runtimeID { return entry }
        if let entry = pool.entries.first(where: { $0.runtimeID == agent.runtimeID }) { return entry }
        return Self.ownEntry(runtimeID: agent.runtimeID)
    }

    /// A runtime as it runs with no pool: its own sign-in, on an allowance, except
    /// Gemini, which only ever runs on its key (046).
    static func ownEntry(runtimeID: String) -> PoolEntry {
        if runtimeID == RuntimeCatalog.gemini.id {
            return PoolEntry(runtimeID: runtimeID, payment: .freeTier(reset: .gemini),
                             credentialRef: CredentialKind.geminiAPIKey.rawValue)
        }
        return PoolEntry(runtimeID: runtimeID, payment: .allowance(label: nil))
    }

    /// The entry a credential key is for: the pool's, where a pool still names it, or
    /// the runtime's own (065: every runtime is tracked, pool or none).
    func entry(forKey key: String) -> PoolEntry {
        if let entry = pool.entries.first(where: { AllowanceState.credentialKey(for: $0) == key }) { return entry }
        let own = Self.ownEntry(runtimeID: AllowanceState.runtimeID(of: key))
        return AllowanceState.credentialKey(for: own) == key
            ? own : PoolEntry(runtimeID: own.runtimeID, payment: .allowance(label: nil),
                              credentialRef: String(key.dropFirst(own.runtimeID.count + 1)))
    }

    /// The state of an entry's credential, made on first use.
    func allowanceState(for entry: PoolEntry) -> AllowanceState {
        let key = AllowanceState.credentialKey(for: entry)
        return allowances[key] ?? AllowanceState(credentialKey: key, entryID: entry.id, since: now())
    }

    func setAllowanceState(_ state: AllowanceState) {
        allowances[state.credentialKey] = state
        do {
            try poolStore.saveAllowances(allowances.values.sorted { $0.credentialKey < $1.credentialKey })
            broadcastPool()
        } catch {
            DaemonLog.shared.write("allowances could not be written: \(error)")
        }
    }

    // MARK: Recognising

    /// What a turn's ending says about the allowance of the runtime it was on.
    func recognise(agentID: UUID, failure: SessionFailure? = nil, error: (any Error)? = nil,
                   runtimeError: String? = nil, rateLimit: RateLimitInfo? = nil) -> Recognition {
        guard let agent = agents[agentID] else { return .none }
        if let rateLimit { latestRateLimit[agentID] = rateLimit }
        let entry = poolEntry(for: agent)
        let rpc = error.flatMap { $0 as? JSONRPCError }.map(\.refusalForLimit)
        let recognition = LimitRecognition.classify(failure: failure, error: rpc, runtimeError: runtimeError,
                                                    runtimeID: agent.runtimeID,
                                                    rateLimit: latestRateLimit[agentID], payment: entry.payment)
        if case .none = recognition, let error, rpc != nil {
            // Layer 3: nothing recognised, and nothing moves. Logged whole so its words
            // can be added when it turns out to have been a limit (R1).
            DaemonLog.shared.write("052 unrecognised refusal: agent \(agentID) \(agent.runtimeID): \(error)")
        }
        return recognition
    }

    /// Act on a recognised limit at the end of a turn: say it on this chat, mark the
    /// runtime, and choose how the turn ends. Nothing carries the chat on (065): the
    /// person starts another and asks it to read this one. Returns true when the turn
    /// will be sent again (a rate limit being retried), so the caller leaves the agent
    /// to that.
    func applyRecognition(_ recognition: Recognition, agentID: UUID, reason: inout EndedReason) async -> Bool {
        guard let agent = agents[agentID] else { return false }
        let entry = poolEntry(for: agent)
        var state = allowanceState(for: entry)
        let at = now()
        switch recognition {
        case .none, .otherTyped:
            return false
        case .spent(let resetsAt):
            state.lastRateLimit = latestRateLimit[agentID] ?? state.lastRateLimit
            state.markOut(.allowanceSpent, until: resetsAt, payment: entry.payment, now: at, from: .typedFailure)
            setAllowanceState(state)
            raiseAllowanceOut(entry, state: state, reason: "allowance spent")
            await record(.runtimeNote(PoolWords.ranOut(agent.runtimeID, state: state, now: at)), for: agentID)
            reason = .allowanceSpent
        case .creditGone:
            state.markOut(.creditUsedUp, until: nil, payment: entry.payment, now: at, from: .words)
            setAllowanceState(state)
            raiseAllowanceOut(entry, state: state, reason: "credit used up")
            await record(.runtimeNote(PoolWords.creditGone(agent.runtimeID)), for: agentID)
            reason = .allowanceSpent
        case .overage(let resetsAt):
            state.markOut(.overage, until: resetsAt, payment: entry.payment, now: at, from: .overageReport)
            setAllowanceState(state)
            raiseAllowanceOut(entry, state: state, reason: "paid extra usage began")
            await record(.runtimeNote(PoolWords.overageBegan(agent.runtimeID)), for: agentID)
            // The turn itself may have worked; then it stays worked.
            if reason == .endTurn { return false }
            reason = .allowanceSpent
        case .rateLimited(let retryAfter):
            let attempt = rateLimitAttempts[agentID, default: 0]
            let retryAt = retryAfter ?? at.addingTimeInterval(rateLimitPolicy.delay(forAttempt: attempt))
            let (streak, persists) = rateLimitPolicy.streak(rateLimitStreaks[agentID, default: []], adding: at)
            if persists {
                rateLimitStreaks[agentID] = nil
                rateLimitAttempts[agentID] = nil
                state.markOut(.rateLimitPersisted, until: nil, payment: entry.payment, now: at, from: .typedFailure)
                setAllowanceState(state)
                raiseAllowanceOut(entry, state: state, reason: "still rate limited")
                await record(.runtimeNote(PoolWords.stillRateLimited(agent.runtimeID)), for: agentID)
                reason = .rateLimited
                return false
            }
            rateLimitStreaks[agentID] = streak
            state.rateLimited(now: at, retryAt: retryAt)
            setAllowanceState(state)
            guard let prompt = lastPrompts[agentID] else {
                reason = .rateLimited
                return false
            }
            rateLimitAttempts[agentID] = attempt + 1
            await record(.runtimeNote(PoolWords.rateLimited(agent.runtimeID, retryAt: retryAt, now: at)), for: agentID)
            reason = .rateLimited
            retryLater(agentID: agentID, prompt: prompt, at: retryAt)
            return true
        }
        return false
    }

    /// A turn that worked: whatever held its credential is over, and what it cost is
    /// counted against credit (FR-001b).
    func allowanceWorked(agentID: UUID) async {
        guard let agent = agents[agentID] else { return }
        rateLimitAttempts[agentID] = nil
        rateLimitStreaks[agentID] = nil
        let entry = poolEntry(for: agent)
        var state = allowanceState(for: entry)
        let at = now()
        let before = state
        state.worked(now: at)
        if let rateLimit = latestRateLimit[agentID] { state.lastRateLimit = rateLimit }
        if entry.payment.isCredit {
            let cost = spentThisTurn(agentID: agentID)
            if state.add(cost: cost, payment: entry.payment, now: at) {
                await record(.runtimeNote(PoolWords.creditGone(agent.runtimeID)), for: agentID)
            }
            _ = state.checkExpiry(payment: entry.payment, now: at)
        }
        if state != before { setAllowanceState(state) }
        if before.isOut, !state.isOut { raiseAllowanceBack(entry, how: "worked", after: before) }
    }

    /// A failed runtime leaves the pool even when the failure was not a quota error.
    /// A recognised spent allowance already has its more specific out state.
    func runtimeFailed(agentID: UUID) {
        guard let agent = agents[agentID] else { return }
        markRuntimeFailed(poolEntry(for: agent))
    }

    func runtimeFailed(runtimeID: String) {
        markRuntimeFailed(pool.entries.first(where: { $0.runtimeID == runtimeID }) ?? Self.ownEntry(runtimeID: runtimeID))
    }

    /// Any runtime, pool or none (065): the four-hour check brings it back.
    private func markRuntimeFailed(_ entry: PoolEntry) {
        var state = allowanceState(for: entry)
        guard state.markFailed(now: now()) else { return }
        setAllowanceState(state)
        raiseAllowanceOut(entry, state: state, reason: "runtime failed")
    }

    /// What this agent spent since its turn began, from what it had banked then.
    private func spentThisTurn(agentID: UUID) -> Cost? {
        guard let agent = agents[agentID], let before = lastPrompts[agentID]?.costBefore else { return nil }
        for (currency, total) in agent.costToDate {
            let delta = total - (before[currency] ?? 0)
            if delta > 0 { return Cost(amount: delta, currency: currency) }
        }
        return agent.costToDate.isEmpty ? nil : Cost(amount: 0, currency: agent.costToDate.keys.first!)
    }

    /// Send the same prompt again once the rate limit's wait is over, unless the agent
    /// has moved on: stopped, archived, given another prompt, or already working.
    private func retryLater(agentID: UUID, prompt: SentPrompt, at: Date) {
        let stopsBefore = stops[agentID, default: 0]
        let delay = max(0, at.timeIntervalSince(now()))
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            await self?.retry(agentID: agentID, prompt: prompt, stopsBefore: stopsBefore)
        }
    }

    private func retry(agentID: UUID, prompt: SentPrompt, stopsBefore: Int) async {
        guard stops[agentID, default: 0] == stopsBefore, let agent = agents[agentID],
              agent.state == .stopped, agent.endedReason == .rateLimited,
              agent.queuedPrompts.isEmpty, turnTasks[agentID] == nil else { return }
        do {
            let session = try await liveSession(for: agent)
            await beginTurn(agentID: agentID, text: prompt.text, blocks: prompt.blocks, from: prompt.from,
                            session: session, unlessStoppedSince: stopsBefore, preface: prompt.preface,
                            recorded: false)
        } catch {
            await record(.runtimeNote("Could not try again: \(reason(error))"), for: agentID)
        }
    }

    /// Move a chat to another runtime: the pool's switch and the person's alike (T040,
    /// US5). The new session is made first, so nothing is lost if it cannot start, and
    /// the person's `choices` are checked against what it really offers before anything
    /// about the chat changes. Then the old runtime is let go, the record takes the new
    /// runtime, and the handoff is either sent with the refused words (`resend`) or kept
    /// for the next prompt. True when a turn was started.
    func switchRuntime(_ agentID: UUID, to entry: PoolEntry, reason switchReason: SwitchRecord.Reason, why: String,
                       choices: [String: JSONValue] = [:], resend: Bool) async throws -> Bool {
        guard var agent = agents[agentID] else {
            throw JSONRPCError(code: DaemonAPI.Failure.noSuchAgent, message: "That agent is not here.")
        }
        let current = poolEntry(for: agent)
        let at = now()
        let made = try await freshSession(runtimeID: entry.runtimeID, cwd: agent.cwd, mcpServers: agent.mcpServers,
                                          managesAgents: agent.startedByAgent == nil)
        let options = await made.session.options
        if let refusal = SettingsCarry.refusal(of: choices, options: options, currentMode: currentMode(of: agent),
                                               runtimeName: PoolWords.runtimeName(entry.runtimeID)) {
            await made.session.end(gracePeriod: .seconds(1))
            throw JSONRPCError(code: -32602, message: refusal)
        }

        // What the old runtime was asking can no longer be answered there (T040).
        await closeQuestionsOfAGoneRuntime(agentID)
        await releaseRuntime(for: agentID)
        // Its plan window was the old runtime's: left, it would mark the new one out
        // until the old one's reset. Cleared after the release, which drains the old
        // runtime's last updates, so a late one cannot put it back.
        latestRateLimit[agentID] = nil

        let page = try? await store.transcript(for: agentID, before: nil, limit: 10_000)
        let size = agent.usage?.size ?? 0
        let budget = size > 0 ? min(Handoff.defaultBudget, size * 2) : Handoff.defaultBudget
        let handoff = Handoff.document(entries: page?.entries ?? [], fromRuntime: PoolWords.runtimeName(current.runtimeID),
                                       why: why, budget: budget)

        let carry = SettingsCarry.choosing(choices, over: SettingsCarry.plan(
            from: .init(runtimeID: agent.runtimeID, options: agent.advertisedOptions, values: agent.startOptions.values),
            to: .init(runtimeID: entry.runtimeID, options: options),
            levels: pool.levels, entryModel: entry.fallbackModel,
            extraArguments: agent.startOptions.extraArguments,
            queuedCommands: agent.queuedPrompts.compactMap { prompt in
                prompt.text.hasPrefix("/") ? String(prompt.text.split(separator: " ").first ?? "") : nil
            }))

        let record = SwitchRecord(at: at, agentID: agentID,
                                  from: .init(entryID: agent.poolEntryID, runtimeID: agent.runtimeID,
                                              model: SettingsCarry.model(in: agent.advertisedOptions).flatMap { agent.startOptions.values[$0.id] ?? $0.currentValue }),
                                  to: .init(entryID: pool.entry(entry.id) == nil ? nil : entry.id, runtimeID: entry.runtimeID,
                                            model: carry.values["model"], mode: carry.values["mode"]),
                                  reason: switchReason, carried: carry.rows, dropped: carry.dropped,
                                  shortened: handoff.leftOut, billing: entry.payment,
                                  fromReturnsAt: switchReason == .byHand ? nil
                                      : allowances[AllowanceState.credentialKey(for: current)]?.knownReturn)

        // Everything awaited first, then the record read fresh and written back with no
        // await between, so a prompt queued meanwhile is not written over.
        let commands = await made.session.commands
        agent = agents[agentID] ?? agent
        agent.runtimeID = entry.runtimeID
        agent.runtimeSessionID = made.sessionID
        agent.poolEntryID = pool.entry(entry.id) == nil ? nil : entry.id
        agent.startOptions = StartOptions(values: carry.values, extraArguments: [])
        agent.advertisedOptions = options
        agent.availableCommands = commands
        remember(OptionCache.Entry(options: options, commands: commands),
                 for: OptionCache.key(runtimeID: entry.runtimeID, cwd: agent.cwd, mcpServers: agent.mcpServers))
        changed(agent)
        live[agentID] = made.session
        bindAppToken(made.appToken, to: agentID)
        needsBriefing.insert(agentID)
        listen(to: made.session, agentID: agentID)
        await prepareServing(made.session, agentID: agentID)
        await made.session.apply(agent.startOptions)
        changed(agents[agentID] ?? agent)

        await self.record(.poolSwitch(record), for: agentID)
        await self.record(.handoff(markdown: handoff.markdown, characters: handoff.markdown.count), for: agentID)
        do { try poolStore.append(record) } catch { DaemonLog.shared.write("switch not written: \(error)") }
        raise(EventDraft(name: "agent.runtime_switched", at: at, scope: .project(folder: agent.projectFolder),
                         sentence: "\(LeaseWords.agentName(agent.title)) carried on with \(PoolWords.runtimeName(entry.runtimeID)).",
                         details: ["from": current.runtimeID, "to": entry.runtimeID, "reason": switchReason.rawValue]
                            .merging(agentDetails(agent)) { $1 }))
        broadcastPool()

        let block = Self.handoffBlock(handoff.markdown, agentID: agentID,
                                      embedded: await made.session.initializeResult?.accepts.embeddedContext == true)
        if resend, let prompt = lastPrompts[agentID] {
            await beginTurn(agentID: agentID, text: prompt.text, blocks: [block] + prompt.blocks, from: prompt.from,
                            session: made.session, preface: prompt.preface, recorded: false)
            lastPrompts[agentID] = prompt
            return true
        }
        pendingHandoff[agentID] = handoff.markdown
        return false
    }

    // MARK: Servers (R6, T069)

    /// What another daemon learned about a shared allowance: a plan's sign-in, which a
    /// server spends through the Mac's relay. The newer word wins (by `since`); a key is
    /// never taken from elsewhere. Returns whether anything changed, which is also what
    /// stops the Mac and a server passing the same state back and forth.
    @discardableResult
    public func applyAllowances(_ incoming: [AllowanceState]) -> Bool {
        var changed = false
        for var state in incoming where state.isShared {
            // The later reading wins by its own time: a status can be older than the
            // reading beside it.
            let mine = allowances[state.credentialKey]
            let newerReading = [mine?.reading, state.reading].compactMap { $0 }.max { $0.at < $1.at }
            if var mine, mine.since >= state.since {
                if newerReading != mine.reading {
                    mine.reading = newerReading
                    allowances[state.credentialKey] = mine
                    changed = true
                }
                continue
            }
            state.reading = newerReading
            // The entry id is this daemon's own, for the same credential.
            if let entry = pool.entries.first(where: { AllowanceState.credentialKey(for: $0) == state.credentialKey }) {
                state.entryID = entry.id
            }
            let wasOut = allowances[state.credentialKey]?.isOut ?? false
            allowances[state.credentialKey] = state
            changed = true
            if let entry = pool.entries.first(where: { AllowanceState.credentialKey(for: $0) == state.credentialKey }) {
                if !wasOut, state.isOut { raiseAllowanceOut(entry, state: state, reason: "learned from another host") }
                if wasOut, !state.isOut { raiseAllowanceBack(entry, how: "another host") }
            }
        }
        guard changed else { return false }
        do {
            try poolStore.saveAllowances(allowances.values.sorted { $0.credentialKey < $1.credentialKey })
        } catch {
            DaemonLog.shared.write("allowances could not be written: \(error)")
        }
        broadcastPool()
        return true
    }

    /// The shared allowances as this daemon knows them, for carrying to another.
    public func sharedAllowances() -> [AllowanceState] {
        allowances.values.filter(\.isShared).sorted { $0.credentialKey < $1.credentialKey }
    }

    // MARK: Matching models (US6)

    /// The model and effort options each runtime offers: what it last said in any folder,
    /// newest first; for one never seen, a session started and ended again, which costs no
    /// prompt, at most once in ten minutes.
    public func poolModels(_ runtimeIDs: [String]) async -> [String: [ConfigOption]] {
        if rememberedOptions == nil { rememberedOptions = optionCache.load() }
        var found: [String: [ConfigOption]] = [:]
        for runtimeID in Set(runtimeIDs) {
            let newest = (rememberedOptions ?? [:])
                .filter { $0.key.hasPrefix("\(runtimeID)\t") && !$0.value.options.isEmpty }
                .max { $0.value.savedAt < $1.value.savedAt }?.value.options
            if let newest {
                found[runtimeID] = Self.modelAndEffort(newest)
                continue
            }
            let at = now()
            if let last = modelsProbedAt[runtimeID], at.timeIntervalSince(last) < 600 { continue }
            modelsProbedAt[runtimeID] = at
            let folder = locations.root
            guard let made = try? await freshSession(runtimeID: runtimeID, cwd: folder, mcpServers: [],
                                                      managesAgents: false) else { continue }
            let options = await made.session.options
            await made.session.end(gracePeriod: .seconds(1))
            remember(OptionCache.Entry(options: options, commands: []),
                     for: OptionCache.key(runtimeID: runtimeID, cwd: folder, mcpServers: []))
            found[runtimeID] = Self.modelAndEffort(options)
        }
        return found
    }

    static func modelAndEffort(_ options: [ConfigOption]) -> [ConfigOption] {
        options.filter { SettingsCarry.isModel($0) || $0.category == "thought_level" }
    }

    /// The chat's mode now: what it set, else what its runtime says it is on.
    func currentMode(of agent: Agent) -> JSONValue? {
        guard let option = ModeMemory.modeOption(in: agent.advertisedOptions) else { return nil }
        return agent.startOptions.values[option.id] ?? option.currentValue
    }

    // MARK: Continue with (US5)

    /// `agents/continueWith`: a preview unless confirmed, then the move by hand with
    /// nothing sent until the next prompt; or, with `adjust`, the settings of the runtime
    /// the chat is already on after an automatic switch, from the next turn (FR-029).
    public func continueWith(_ request: DaemonAPI.ContinueWithRequest) async throws -> DaemonAPI.ContinueWithResult {
        guard let agent = agents[request.agentID], agent.state != .archived else {
            throw JSONRPCError(code: DaemonAPI.Failure.noSuchAgent, message: "That agent is not here.")
        }
        if request.adjust { return try await adjustCarry(agent, request) }

        let entry: PoolEntry
        if let id = request.entryID, let found = pool.entry(id) {
            entry = found
        } else if let runtimeID = request.runtimeID, RuntimeCatalog.runtime(id: runtimeID) != nil {
            entry = pool.entries.first { $0.runtimeID == runtimeID && !$0.isKeyed }
                ?? PoolEntry(runtimeID: runtimeID, payment: .allowance(label: nil))
        } else {
            throw JSONRPCError(code: -32602, message: "Say which runtime to continue with.")
        }
        guard entry.runtimeID != agent.runtimeID || entry.id != agent.poolEntryID else {
            throw JSONRPCError(code: -32602, message: "This chat is already on \(PoolWords.runtimeName(entry.runtimeID)).")
        }
        if let why = unusable(entry) {
            throw JSONRPCError(code: -32602, message: "\(PoolWords.runtimeName(entry.runtimeID)) cannot be used: \(why).")
        }

        guard request.confirmed else {
            // What it last offered in this folder: enough to show the plan without
            // starting it. A runtime never run here shows nothing to choose yet.
            let options = rememberedOptions(for: OptionCache.key(runtimeID: entry.runtimeID, cwd: agent.cwd,
                                                                 mcpServers: agent.mcpServers))?.options
                ?? rememberedOptions(.init(runtimeID: entry.runtimeID, cwd: agent.cwd))
            let plan = SettingsCarry.plan(
                from: .init(runtimeID: agent.runtimeID, options: agent.advertisedOptions, values: agent.startOptions.values),
                to: .init(runtimeID: entry.runtimeID, options: options),
                levels: pool.levels, entryModel: entry.fallbackModel,
                extraArguments: agent.startOptions.extraArguments)
            return .init(runtimeID: entry.runtimeID, plan: SettingsCarry.choosing(request.choices, over: plan), options: options)
        }
        guard !agent.state.hasTurnInFlight, turnTasks[agent.id] == nil else {
            throw JSONRPCError(code: DaemonAPI.Failure.stopTheTurnFirst, message: "Stop the turn first.")
        }
        dropAllowanceWait(agent.id)
        let fromModel = SettingsCarry.model(in: agent.advertisedOptions).flatMap {
            agent.startOptions.values[$0.id] ?? $0.currentValue
        }
        _ = try await switchRuntime(agent.id, to: entry, reason: .byHand, why: "you asked to continue with it",
                                    choices: request.choices, resend: false)
        let moved = agents[agent.id]
        // Remember the pair the person chose (US6), never breaking FR-032.
        if let remember = request.remember, let fromModel, let moved,
           let toModel = SettingsCarry.model(in: moved.advertisedOptions).flatMap({ moved.startOptions.values[$0.id] ?? $0.currentValue }) {
            let next = pool.remembering(from: (agent.runtimeID, Cell(model: fromModel)),
                                        to: (entry.runtimeID, Cell(model: toModel)),
                                        levelID: remember.levelID, newLevelName: remember.newLevelName)
            do { _ = try setPool(next) } catch {
                DaemonLog.shared.write("remembering a pair was refused: \(error)")
            }
        }
        return .init(runtimeID: entry.runtimeID,
                     plan: CarryPlan(values: moved?.startOptions.values ?? [:]),
                     options: moved?.advertisedOptions ?? [], agent: moved)
    }

    /// After an automatic switch: the same runtime, other settings, from the next turn.
    /// No new session, and nothing sent again (FR-029).
    private func adjustCarry(_ agent: Agent, _ request: DaemonAPI.ContinueWithRequest) async throws -> DaemonAPI.ContinueWithResult {
        let options = agent.advertisedOptions
        var plan = CarryPlan(values: agent.startOptions.values, rows: options.filter(\.isRenderable).map { option in
            let now = agent.startOptions.values[option.id] ?? option.currentValue
            return CarriedSetting(optionID: option.id, name: option.name, from: now, to: now, source: .sameValue)
        })
        plan = SettingsCarry.choosing(request.choices, over: plan)
        guard request.confirmed else { return .init(runtimeID: agent.runtimeID, plan: plan, options: options) }
        guard !agent.state.hasTurnInFlight, turnTasks[agent.id] == nil else {
            throw JSONRPCError(code: DaemonAPI.Failure.stopTheTurnFirst, message: "Stop the turn first.")
        }
        // The limit is the mode the chat had before it moved, which the switch record keeps.
        let before = poolStore.switches(since: .distantPast).last { $0.agentID == agent.id }
        let limit = before?.carried.first { $0.optionID == ModeMemory.modeOption(in: options)?.id }?.from
            ?? currentMode(of: agent)
        if let refusal = SettingsCarry.refusal(of: request.choices, options: options, currentMode: limit,
                                               runtimeName: PoolWords.runtimeName(agent.runtimeID)) {
            throw JSONRPCError(code: -32602, message: refusal)
        }
        var changed = agent
        for (id, value) in request.choices { changed.startOptions.values[id] = value }
        self.changed(changed)
        if let session = live[agent.id] { await session.apply(changed.startOptions) }
        let record = SwitchRecord(at: now(), agentID: agent.id,
                                  from: .init(entryID: agent.poolEntryID, runtimeID: agent.runtimeID),
                                  to: .init(entryID: agent.poolEntryID, runtimeID: agent.runtimeID,
                                            model: changed.startOptions.values["model"], mode: changed.startOptions.values["mode"]),
                                  reason: .byHand, carried: plan.rows.filter { request.choices[$0.optionID] != nil },
                                  billing: poolEntry(for: agent).payment)
        await self.record(.settingsChanged(record), for: agent.id)
        return .init(runtimeID: agent.runtimeID, plan: plan, options: options, agent: changed)
    }

    // MARK: Waits left from 052 (US4)

    /// A wait saved by an older build: cleared at launch and never resumed (065). The
    /// chat stays where it ended; the note it already has says why.
    func clearAllowanceWaitsLeftFromBefore() {
        for (id, agent) in agents where agent.allowanceWait != nil {
            var cleared = agent
            cleared.allowanceWait = nil
            if cleared.state == .stopped, cleared.endedReason == nil { cleared.endedReason = .allowanceSpent }
            changed(cleared)
            DaemonLog.shared.write("065: cleared an allowance wait left from before on agent \(id)")
        }
    }

    /// Drop a chat's wait: the person prompted, stopped, parked or archived it (FR-017),
    /// or it has just been resumed. Says nothing; whatever dropped it says what it did.
    func dropAllowanceWait(_ agentID: UUID) {
        guard var agent = agents[agentID], agent.allowanceWait != nil else { return }
        agent.allowanceWait = nil
        changed(agent)
        broadcastPool()
    }

    /// Stop waiting, from the Pool page or the phone (US4).
    public func stopWaitingForAllowance(_ agentID: UUID) async {
        guard agents[agentID]?.allowanceWait != nil else { return }
        dropAllowanceWait(agentID)
        await record(.runtimeNote(PoolWords.stoppedWaiting), for: agentID)
    }

    /// This chat's own switch (FR-011a): off keeps it on its runtime whatever the pool
    /// says. The window's control for it is US5's `agents/setSwitching`.
    func setSwitching(agentID: UUID, off: Bool) async {
        guard var agent = agents[agentID], agent.switchingOff != off else { return }
        agent.switchingOff = off
        changed(agent)
    }

    /// The handoff as the new runtime takes it: embedded, where it says it can hold
    /// embedded context, and as plain text where it cannot.
    static func handoffBlock(_ markdown: String, agentID: UUID, embedded: Bool) -> ContentBlock {
        embedded ? .resource(uri: "agents://handoff/\(agentID.uuidString).md", text: markdown, blob: nil,
                             mimeType: "text/markdown")
                 : .text(markdown)
    }

    /// An allowance just went out, on the Mac's event log (042).
    func raiseAllowanceOut(_ entry: PoolEntry, state: AllowanceState, reason: String) {
        var details = ["runtime": entry.runtimeID, "reason": reason]
        // "until" only for a time the provider gave; the app's own retry is said as that.
        if let until = state.knownReturn { details["until"] = ISO8601DateFormatter().string(from: until) }
        if case .out(_, let retry?, _) = state.status {
            details["retry_after"] = ISO8601DateFormatter().string(from: retry)
        }
        let sentence: String
        if case .out(_, let retry, .runtimeFailed) = state.status {
            let name = PoolWords.runtimeName(entry.runtimeID)
            sentence = retry.map { "\(name) failed. The app checks it again at \(PoolWords.time($0, now: now()))." }
                ?? "\(name) failed."
        } else {
            sentence = "\(PoolWords.runtimeName(entry.runtimeID))’s allowance ran out."
        }
        raise(EventDraft(name: "cost.allowance_out", at: now(), scope: .mac,
                         sentence: sentence, details: details))
    }

    /// An allowance came back: the person said so, or a turn on it worked (042).
    /// `after` is the state it came back from: a runtime that failed did not run out.
    func raiseAllowanceBack(_ entry: PoolEntry, how: String, after: AllowanceState? = nil) {
        let name = PoolWords.runtimeName(entry.runtimeID)
        let failed = if case .out(_, _, .runtimeFailed) = after?.status { true } else { false }
        raise(EventDraft(name: "cost.allowance_back", at: now(), scope: .mac,
                         sentence: failed ? "\(name) is working again." : "\(name)’s allowance came back.",
                         details: ["runtime": entry.runtimeID, "how": how]))
    }

    // MARK: The Pool page

    /// What the Pool page draws (US3). An entry nobody has used yet is available.
    public func poolStatus(days: Int? = nil) -> PoolStatus {
        let at = now()
        let states = settledStates(at: at)
        let live = agents.values.filter { $0.state != .archived }
        let rows = pool.entries.map { entry -> PoolStatus.Row in
            let key = AllowanceState.credentialKey(for: entry)
            let state = states[key] ?? AllowanceState(credentialKey: key, entryID: entry.id, since: at)
            let chats = live.filter { AllowanceState.credentialKey(for: poolEntry(for: $0)) == key }.count
            return PoolStatus.Row(entry: entry, state: state, chats: chats, unusable: unusable(entry))
        }
        let since = at.addingTimeInterval(-Double(min(max(days ?? 1, 1), 30)) * 86400)
        let switches = poolStore.switches(since: since).sorted { $0.at > $1.at }
        let titles = Dictionary(switches.compactMap { record in
            agents[record.agentID].map { (record.agentID, $0.title ?? "Untitled") }
        }, uniquingKeysWith: { first, _ in first })
        let waiting = live.compactMap { agent in
            agent.allowanceWait.map { PoolStatus.Waiting(agentID: agent.id, runtimeID: $0.runtimeID, resumeAt: $0.resumeAt) }
        }.sorted { $0.resumeAt < $1.resumeAt }
        var named = titles
        for wait in waiting { named[wait.agentID] = agents[wait.agentID]?.title ?? "Untitled" }
        var status = PoolStatus(settings: pool, rows: rows, waiting: waiting, switches: switches, titles: named, at: at)
        status.shared = sharedAllowances()
        return status
    }

    /// Keep a new pool, whole (contracts/daemon-api.md). Refused, with the sentence the
    /// Settings page shows, when it breaks a rule: a key as an allowance, an amount of
    /// nothing, a model in two levels.
    public func setPool(_ next: PoolSettings) throws -> PoolStatus {
        do {
            try next.validate()
        } catch {
            throw JSONRPCError(code: -32602, message: error.sentence)
        }
        pool = next
        try poolStore.save(next)
        // A changed amount or date counts now, not at the next turn (US2-AS7, AS8).
        let at = now()
        for entry in next.entries where entry.payment.isCredit {
            var state = allowanceState(for: entry)
            let wasOut = state.isOut
            guard state.reconcile(payment: entry.payment, now: at) else { continue }
            setAllowanceState(state)
            if wasOut, !state.isOut { raiseAllowanceBack(entry, how: "person") }
        }
        broadcastPool()
        return poolStatus()
    }

    /// Every credential's state as of `at`, for deciding and for showing: return times
    /// that have passed are over, and credit is judged against what its entry says now.
    /// An entry nobody has used yet is in it too, so an expired grant is out before it is
    /// ever tried. Nothing is written.
    func settledStates(at: Date) -> [String: AllowanceState] {
        var states = allowances
        for key in states.keys { states[key]?.settle(now: at) }
        for entry in pool.entries {
            let key = AllowanceState.credentialKey(for: entry)
            var state = states[key] ?? AllowanceState(credentialKey: key, entryID: entry.id, since: at)
            state.reconcile(payment: entry.payment, now: at)
            states[key] = state
        }
        return states
    }

    /// Every runtime's state, pool or none (065, US4): a row for each runtime this Mac
    /// finds, and one for any other credential with a state. A runtime nothing has
    /// happened to is available.
    public func runtimeAllowances() -> RuntimeAllowances {
        let at = now()
        var keys: [String] = []
        for runtime in RuntimeCatalog.builtIn {
            if case .missing = discovery.locate(runtime) { continue }
            keys.append(AllowanceState.credentialKey(for: Self.ownEntry(runtimeID: runtime.id)))
        }
        for key in allowances.keys.sorted() where !keys.contains(key) { keys.append(key) }
        let rows = keys.map { key -> RuntimeAllowances.Row in
            let entry = entry(forKey: key)
            var state = allowances[key] ?? AllowanceState(credentialKey: key, entryID: entry.id, since: at)
            state.settle(now: at)
            return RuntimeAllowances.Row(credentialKey: key, state: state, unusable: unusable(entry))
        }
        return RuntimeAllowances(rows: rows, at: at)
    }

    /// The person says a runtime is back, by its credential (065). Idempotent.
    public func markRuntimeAvailable(credentialKey key: String) -> RuntimeAllowances {
        if var state = allowances[key] {
            let wasOut = state.isOut
            state.markAvailable(now: now())
            setAllowanceState(state)
            if wasOut { raiseAllowanceBack(entry(forKey: key), how: "person") }
        }
        return runtimeAllowances()
    }

    /// The person says a credential is back (FR-023). Idempotent; open to paired devices.
    public func markPoolEntryAvailable(_ entryID: UUID) -> PoolStatus {
        if let entry = pool.entry(entryID) {
            var state = allowanceState(for: entry)
            let wasOut = state.isOut
            state.markAvailable(now: now())
            setAllowanceState(state)
            if wasOut { raiseAllowanceBack(entry, how: "person") }
            broadcastPool()
        }
        return poolStatus()
    }

    /// Tell every window the pool changed.
    ///
    /// At most once a second: a change inside the second after the last one is held,
    /// and the one broadcast at the end of it carries the state as it is then.
    func broadcastPool() {
        let clock = ContinuousClock()
        if let last = poolBroadcastAt, clock.now - last < Self.poolBroadcastGap {
            guard !poolBroadcastHeld else { return }
            poolBroadcastHeld = true
            let wait = Self.poolBroadcastGap - (clock.now - last)
            Task {
                try? await Task.sleep(for: wait)
                await self.sendHeldPoolBroadcast()
            }
            return
        }
        poolBroadcastAt = clock.now
        broadcast(DaemonAPI.Notification.poolChanged, poolStatus())
        broadcast(DaemonAPI.Notification.runtimesAllowancesChanged, runtimeAllowances())
    }

    static let poolBroadcastGap: Duration = .seconds(1)

    private func sendHeldPoolBroadcast() {
        poolBroadcastHeld = false
        poolBroadcastAt = ContinuousClock().now
        broadcast(DaemonAPI.Notification.poolChanged, poolStatus())
        broadcast(DaemonAPI.Notification.runtimesAllowancesChanged, runtimeAllowances())
    }

    /// The pool's clocks, on the workflow heartbeat (no timer of its own): short
    /// rate limits expire, and grants past their date become out.
    func settlePoolClocks(now at: Date) {
        var changed = false
        for key in Array(allowances.keys) {
            guard var state = allowances[key], state.isOut || state.status != .available else { continue }
            let wasOut = state.isOut
            guard state.settle(now: at) else { continue }
            allowances[key] = state
            changed = true
            if wasOut, !state.isOut, let entry = pool.entries.first(where: { AllowanceState.credentialKey(for: $0) == key }) {
                raiseAllowanceBack(entry, how: "time")
            }
        }
        for entry in pool.entries where entry.payment.expires != nil {
            var state = allowanceState(for: entry)
            guard state.checkExpiry(payment: entry.payment, now: at) else { continue }
            allowances[state.credentialKey] = state
            changed = true
            raiseAllowanceOut(entry, state: state, reason: "credit expired")
        }
        guard changed else { return }
        do {
            try poolStore.saveAllowances(allowances.values.sorted { $0.credentialKey < $1.credentialKey })
        } catch {
            DaemonLog.shared.write("allowances could not be written: \(error)")
        }
        broadcastPool()
    }

    /// Check out credentials every four hours. The retry date is only permission to
    /// ask: it never makes an unverified runtime usable by itself.
    func checkDueAllowances(now at: Date) {
        // Every credential with a state, pool or none (065), each once.
        var seen: Set<String> = []
        let entries = allowances.keys.sorted().map { entry(forKey: $0) }
            .filter { seen.insert(AllowanceState.credentialKey(for: $0)).inserted }
        for entry in entries {
            let key = AllowanceState.credentialKey(for: entry)
            if !entry.payment.isCredit, var state = allowances[key],
               case .out(let until, let retry, let why) = state.status {
                let firstCheck = state.since.addingTimeInterval(AllowanceState.retryWithoutATime)
                if retry.map({ $0 < firstCheck }) ?? true {
                    state.status = .out(until: until, retryAfter: firstCheck, why: why)
                    setAllowanceState(state)
                }
            }
            guard !allowanceChecks.contains(key),
                  let state = allowances[key],
                  case .out(_, let retry?, _) = state.status,
                  retry <= at else { continue }
            allowanceChecks.insert(key)
            Task { [weak self] in
                await self?.checkAllowance(entry, expected: state)
            }
        }
    }

    private func checkAllowance(_ entry: PoolEntry, expected: AllowanceState) async {
        let key = expected.credentialKey
        defer { allowanceChecks.remove(key) }
        let passed = await probeAllowance(runtimeID: entry.runtimeID)
        guard var state = allowances[key], state.status == expected.status,
              state.since == expected.since else { return }
        let at = now()
        if passed {
            markSignedIn(runtimeID: entry.runtimeID)
            state.worked(now: at)
            setAllowanceState(state)
            raiseAllowanceBack(entry, how: "check", after: expected)
        } else {
            state.deferCheck(now: at)
            setAllowanceState(state)
        }
    }

    /// A separate, short conversation in the daemon's own folder. It has no app tools
    /// or project content, and a read-only mode wherever the runtime advertises one.
    private func probeAllowance(runtimeID: String) async -> Bool {
        var session: ACPSession?
        var chosen: [String] = []
        do {
            let (made, _) = try await handshakeOnly(runtimeID: runtimeID)
            session = made
            defer { Task { await made.end(gracePeriod: .seconds(1)) } }
            try await made.newSession(cwd: locations.root)
            let options = await made.options
            if let mode = ModeMemory.modeOption(in: options),
               let choice = mode.options?.first(where: {
                   guard let value = $0.value.stringValue else { return false }
                   return ["plan", "ask", "read-only"].contains(value.split(separator: "#").last.map(String.init) ?? value)
               }) {
                try await made.setOption(id: mode.id, value: choice.value)
                chosen.append("mode \(choice.value.stringValue ?? choice.name)")
            } else if ModeMemory.modeOption(in: options) != nil {
                DaemonLog.shared.write("pool check for \(runtimeID): failed, no read-only mode to check in")
                return false
            }
            if let model = WorkflowSettings.modelOption(in: options),
               let choice = Self.probeModel(in: model.options ?? []) {
                try await made.setOption(id: model.id, value: choice.value)
                chosen.append("model \(choice.value.stringValue ?? choice.name)")
            }
            let replies = Task { () -> String in
                var text = ""
                for await event in made.eventStream() {
                    if case .entry(.agentMessage(_, let words, _)) = event { text += words }
                }
                return text
            }
            let timeout = Task {
                try? await Task.sleep(for: .seconds(45))
                if !Task.isCancelled { await made.end(gracePeriod: .seconds(1)) }
            }
            defer { timeout.cancel() }
            let answer = try await made.prompt("Reply with OK. Do not use tools or edit files.")
            await made.end(gracePeriod: .seconds(1))
            let reply = await replies.value.trimmingCharacters(in: .whitespacesAndNewlines)
            let recognition = LimitRecognition.classify(failure: answer.failure,
                                                        runtimeError: answer.runtimeError?.sentence ?? reply,
                                                        runtimeID: runtimeID, rateLimit: answer.rateLimit)
            let passed = answer.reason == .endTurn && answer.failure == nil && answer.runtimeError == nil
                && recognition == .none && answer.rateLimit?.isRejected != true
                && ["ok", "ok."].contains(reply.lowercased())
            DaemonLog.shared.write("pool check for \(runtimeID): \(passed ? "passed" : "failed") "
                                   + "(\(chosen.joined(separator: ", ")); reply \(reply.prefix(80).debugDescription))")
            return passed
        } catch {
            DaemonLog.shared.write("pool check failed for \(runtimeID): \(error)")
            if let session { await session.end(gracePeriod: .seconds(1)) }
            return false
        }
    }

    /// Runtime options have no prices. The first of the small model families the runtimes
    /// advertise, by name or in their own description ("Fast and affordable"). Nil when
    /// none says it is small: the runtime's default then stays, rather than the first
    /// in its list, which is often its largest.
    static func probeModel(in choices: [ConfigChoice]) -> ConfigChoice? {
        let small = ["nano", "flash-lite", "haiku", "mini", "flash", "small", "lite", "fast", "affordable"]
        func rank(_ choice: ConfigChoice) -> Int? {
            let words = "\(choice.name) \(choice.value.stringValue ?? "") \(choice.description ?? "")".lowercased()
            return small.firstIndex { words.contains($0) }
        }
        return choices.compactMap { choice in rank(choice).map { (choice, $0) } }
            .min { $0.1 < $1.1 }?.0
    }

    /// Why an entry cannot be used at all, in the page's words.
    func unusable(_ entry: PoolEntry) -> String? {
        guard let runtime = RuntimeCatalog.runtime(id: entry.runtimeID) else { return "not a runtime this app knows" }
        switch discovery.locate(runtime) {
        case .missing, .installFailed: return "not installed"
        case .needsSignIn: return "not signed in"
        default: break
        }
        if accounts[entry.runtimeID]?.state == .needsSignIn { return "not signed in" }
        return nil
    }

    /// Every credential's state, for the Pool page and for tests.
    public func allowanceStates() -> [AllowanceState] {
        allowances.values.sorted { $0.credentialKey < $1.credentialKey }
    }

    /// For tests: shorter waits between rate-limit retries.
    func useRateLimitPolicy(_ policy: RateLimitPolicy) {
        rateLimitPolicy = policy
    }

    /// The plan window a runtime reported during a turn (R2): kept for the turn's end,
    /// and on the credential for the Pool page.
    func notePlanWindow(_ info: RateLimitInfo, agentID: UUID) {
        latestRateLimit[agentID] = info
        let at = now()
        if let agent = agents[agentID], let reading = AllowanceReading.claude(info, at: at) {
            noteReading(reading, for: poolEntry(for: agent))
        }
        // Late: a plan window saying when it is back can be read after the refusal it
        // explains, which was then recorded with no time. Put the time in, so the page
        // shows the provider's reset; the four-hour check still decides when it is back (R2).
        guard info.isRejected, let back = info.resetsAt, back > at, let agent = agents[agentID] else { return }
        let entry = poolEntry(for: agent)
        guard var state = allowances[AllowanceState.credentialKey(for: entry)],
              case .out(nil, let retry, .allowanceSpent) = state.status,
              at.timeIntervalSince(state.since) < 60 else { return }
        state.status = .out(until: back, retryAfter: retry, why: .allowanceSpent)
        setAllowanceState(state)
    }

    // MARK: Readings

    /// Keep what a runtime said is left of its plan window, for the Pool page. The
    /// same reading again is not written until it is five minutes older, since Claude
    /// repeats it on every `usage_update`.
    func noteReading(_ reading: AllowanceReading, for entry: PoolEntry) {
        var state = allowanceState(for: entry)
        if let before = state.reading, before.sameAs(reading),
           reading.at.timeIntervalSince(before.at) < Self.readingKeptFor { return }
        state.reading = reading
        setAllowanceState(state)
    }

    /// How long a reading asked for stands before the Pool page asks again.
    static let readingKeptFor: TimeInterval = 300

    /// Ask each runtime that can say what is left of its plan, where the last answer is
    /// older than `readingKeptFor`. Grok, whether or not a pool names it (065). Grok is the one that can be asked;
    /// Claude says it during turns, unasked. Each ask starts the runtime for a moment,
    /// as signing in does. Runs behind the Pool page: the page draws what is known
    /// now, and the answer arrives as `pool/changed`.
    func measureAllowances() async {
        let at = now()
        var seen: Set<String> = []
        let candidates = (pool.entries + [Self.ownEntry(runtimeID: RuntimeCatalog.grok.id)])
            .filter { seen.insert(AllowanceState.credentialKey(for: $0)).inserted }
        let asked = candidates.filter { entry in
            guard entry.runtimeID == RuntimeCatalog.grok.id, !entry.isKeyed, unusable(entry) == nil else { return false }
            let key = AllowanceState.credentialKey(for: entry)
            guard !measuringAllowances.contains(key) else { return false }
            guard let last = allowances[key]?.reading else { return true }
            return at.timeIntervalSince(last.at) >= Self.readingKeptFor
        }
        for entry in asked {
            let key = AllowanceState.credentialKey(for: entry)
            measuringAllowances.insert(key)
            defer { measuringAllowances.remove(key) }
            do {
                let (session, _) = try await handshakeOnly(runtimeID: entry.runtimeID)
                let reading = try? await session.grokAllowance(at: now())
                await session.end(gracePeriod: .seconds(2))
                if let reading { noteReading(reading, for: entry) }
            } catch {
                DaemonLog.shared.write("allowance not measured for \(key): \(error)")
            }
        }
    }
}
