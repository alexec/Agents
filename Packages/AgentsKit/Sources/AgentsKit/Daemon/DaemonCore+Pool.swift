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
        if agent.runtimeID == RuntimeCatalog.gemini.id {
            return PoolEntry(runtimeID: agent.runtimeID, payment: .freeTier(reset: .gemini),
                             credentialRef: CredentialKind.geminiAPIKey.rawValue)
        }
        return PoolEntry(runtimeID: agent.runtimeID, payment: .allowance(label: nil))
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
        let rpc = error.flatMap { $0 as? JSONRPCError }.map { (code: $0.code, message: $0.message) }
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

    /// Act on a recognised limit at the end of a turn: say it, mark the credential, and
    /// choose how the turn ends. Returns true when the turn will be sent again (a rate
    /// limit being retried), so the caller leaves the agent to that.
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
            if !willCarry(agent) {
                await record(.runtimeNote(PoolWords.ranOut(agent.runtimeID, returnsAt: state.returnsAt, now: at)), for: agentID)
            }
            pendingCarry[agentID] = (.allowanceSpent, true)
            reason = .allowanceSpent
        case .creditGone:
            state.markOut(.creditUsedUp, until: nil, payment: entry.payment, now: at, from: .words)
            setAllowanceState(state)
            raiseAllowanceOut(entry, state: state, reason: "credit used up")
            if !willCarry(agent) { await record(.runtimeNote(PoolWords.creditGone(agent.runtimeID)), for: agentID) }
            pendingCarry[agentID] = (.creditUsedUp, true)
            reason = .allowanceSpent
        case .overage(let resetsAt):
            state.markOut(.overage, until: resetsAt, payment: entry.payment, now: at, from: .overageReport)
            setAllowanceState(state)
            raiseAllowanceOut(entry, state: state, reason: "paid extra usage began")
            if !willCarry(agent) { await record(.runtimeNote(PoolWords.overageBegan(agent.runtimeID)), for: agentID) }
            // The turn itself may have worked; then only the next one goes elsewhere.
            pendingCarry[agentID] = (.overage, reason != .endTurn)
            if reason == .endTurn { return false }
            reason = .allowanceSpent
        case .rateLimited(let retryAfter):
            let attempt = rateLimitAttempts[agentID, default: 0]
            let retryAt = retryAfter ?? at.addingTimeInterval(rateLimitPolicy.delay(forAttempt: attempt))
            if state.rateLimited(now: at, retryAt: retryAt, payment: entry.payment, policy: rateLimitPolicy) {
                setAllowanceState(state)
                rateLimitAttempts[agentID] = nil
                raiseAllowanceOut(entry, state: state, reason: "still rate limited")
                if !willCarry(agent) { await record(.runtimeNote(PoolWords.stillRateLimited(agent.runtimeID)), for: agentID) }
                pendingCarry[agentID] = (.rateLimitPersisted, true)
                reason = .rateLimited
                return false
            }
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
        carryTried[agentID] = nil
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
        if before.isOut, !state.isOut { raiseAllowanceBack(entry, how: "worked") }
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

    // MARK: Carrying on (US1)

    /// Whether a spent allowance will move this chat, so the note that it stopped is
    /// not written only to be followed by the note that it moved.
    func willCarry(_ agent: Agent) -> Bool {
        pool.isEffective && !agent.switchingOff
    }

    /// Carry a chat on with the next entry, once its old runtime has been let go (FR-009
    /// to FR-015). Called at the two places a turn ends. Nothing happens unless a spent
    /// allowance was recognised this turn. True when a turn was started on the new
    /// runtime; false when there was nowhere to go, or when the handoff waits for the
    /// next prompt, so the caller carries on as for any ending.
    @discardableResult
    func carryOnIfPending(_ agentID: UUID) async -> Bool {
        guard let pending = pendingCarry.removeValue(forKey: agentID),
              var agent = agents[agentID], agent.state != .archived else { return false }
        let current = poolEntry(for: agent)
        var tried = carryTried[agentID, default: []]
        tried.insert(AllowanceState.credentialKey(for: current))
        let at = now()
        let states = settledStates(at: at)
        let decision = PoolPlan.next(current: current, pool: pool, switchingOff: agent.switchingOff,
                                     states: states, tried: tried, unusable: { self.unusable($0) }, now: at)
        guard case .switchTo(let entry) = decision else {
            await record(.runtimeNote(PoolWords.ranOut(current.runtimeID,
                                                       returnsAt: allowances[AllowanceState.credentialKey(for: current)]?.returnsAt,
                                                       now: at)), for: agentID)
            if case .everyoneOut(let earliest) = decision {
                let back = earliest.map { " The first is back at \(PoolWords.time($0, now: at))." } ?? ""
                await record(.runtimeNote("Every other runtime in the pool is out too, so this chat stopped here.\(back)"),
                             for: agentID)
            }
            return false
        }
        tried.insert(AllowanceState.credentialKey(for: entry))
        carryTried[agentID] = tried
        // What the old runtime was asking can no longer be answered there (T040).
        await closeQuestionsOfAGoneRuntime(agentID)
        await releaseRuntime(for: agentID)

        let fromName = PoolWords.runtimeName(current.runtimeID)
        let why = switch pending.reason {
        case .overage: "it started using paid extra usage"
        case .creditUsedUp: "its credit was used up"
        case .rateLimitPersisted: "it stayed rate limited"
        default: "its allowance ran out"
        }
        let page = try? await store.transcript(for: agentID, before: nil, limit: 10_000)
        let size = agent.usage?.size ?? 0
        let budget = size > 0 ? min(Handoff.defaultBudget, size * 2) : Handoff.defaultBudget
        let handoff = Handoff.document(entries: page?.entries ?? [], fromRuntime: fromName, why: why, budget: budget)

        let made: MadeSession
        do {
            made = try await freshSession(runtimeID: entry.runtimeID, cwd: agent.cwd, mcpServers: agent.mcpServers,
                                          managesAgents: agent.startedByAgent == nil)
        } catch {
            await record(.runtimeNote("Could not carry on with \(PoolWords.runtimeName(entry.runtimeID)): \(reason(error))"),
                         for: agentID)
            return false
        }
        let options = await made.session.options
        let carry = SettingsCarry.plan(
            from: .init(runtimeID: agent.runtimeID, options: agent.advertisedOptions, values: agent.startOptions.values),
            to: .init(runtimeID: entry.runtimeID, options: options),
            levels: pool.levels, entryModel: entry.fallbackModel,
            extraArguments: agent.startOptions.extraArguments,
            queuedCommands: agent.queuedPrompts.compactMap { prompt in
                prompt.text.hasPrefix("/") ? String(prompt.text.split(separator: " ").first ?? "") : nil
            })

        let record = SwitchRecord(at: at, agentID: agentID,
                                  from: .init(entryID: agent.poolEntryID, runtimeID: agent.runtimeID,
                                              model: SettingsCarry.model(in: agent.advertisedOptions).flatMap { agent.startOptions.values[$0.id] ?? $0.currentValue }),
                                  to: .init(entryID: entry.id, runtimeID: entry.runtimeID,
                                            model: carry.values["model"], mode: carry.values["mode"]),
                                  reason: pending.reason, carried: carry.rows, dropped: carry.dropped,
                                  shortened: handoff.leftOut, billing: entry.payment,
                                  fromReturnsAt: allowances[AllowanceState.credentialKey(for: current)]?.returnsAt)

        agent = agents[agentID] ?? agent
        agent.runtimeID = entry.runtimeID
        agent.runtimeSessionID = made.sessionID
        agent.poolEntryID = entry.id
        agent.startOptions = StartOptions(values: carry.values, extraArguments: [])
        agent.advertisedOptions = options
        agent.availableCommands = await made.session.commands
        agents[agentID] = agent
        try? await store.save(agent)
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
                         details: ["from": current.runtimeID, "to": entry.runtimeID, "reason": pending.reason.rawValue]
                            .merging(agentDetails(agent)) { $1 }))
        broadcastPool()

        let block = Self.handoffBlock(handoff.markdown, agentID: agentID,
                                      embedded: await made.session.initializeResult?.accepts.embeddedContext == true)
        if pending.resend, let prompt = lastPrompts[agentID] {
            await beginTurn(agentID: agentID, text: prompt.text, blocks: [block] + prompt.blocks, from: prompt.from,
                            session: made.session, preface: prompt.preface, recorded: false)
            lastPrompts[agentID] = prompt
            return true
        }
        pendingHandoff[agentID] = handoff.markdown
        return false
    }

    /// This chat's own switch (FR-011a): off keeps it on its runtime whatever the pool
    /// says. The window's control for it is US5's `agents/setSwitching`.
    func setSwitching(agentID: UUID, off: Bool) async {
        guard var agent = agents[agentID], agent.switchingOff != off else { return }
        agent.switchingOff = off
        try? await store.save(agent)
        changed(agent)
    }

    /// A chat whose runtime is already known to be out moves before its turn rather than
    /// failing first (FR-012, US3-AS5). Only when there is somewhere to go: otherwise the
    /// turn is tried, and whatever the runtime says is heard as usual.
    func moveFirstIfOut(_ agentID: UUID) async {
        guard pool.isEffective, let agent = agents[agentID], !agent.switchingOff else { return }
        let current = poolEntry(for: agent)
        let at = now()
        let states = settledStates(at: at)
        guard let state = states[AllowanceState.credentialKey(for: current)], state.isOut else { return }
        let decision = PoolPlan.next(current: current, pool: pool, switchingOff: false, states: states,
                                     tried: [AllowanceState.credentialKey(for: current)],
                                     unusable: { self.unusable($0) }, now: at)
        guard case .switchTo = decision else { return }
        pendingCarry[agentID] = (Self.carryReason(state), false)
        await carryOnIfPending(agentID)
    }

    /// Why an out credential is out, as a switch says it.
    static func carryReason(_ state: AllowanceState) -> SwitchRecord.Reason {
        switch state.status {
        case .out(_, _, .overage): .overage
        case .out(_, _, .creditUsedUp), .out(_, _, .creditExpired): .creditUsedUp
        case .out(_, _, .rateLimitPersisted): .rateLimitPersisted
        default: .allowanceSpent
        }
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
        if let until = state.returnsAt { details["until"] = ISO8601DateFormatter().string(from: until) }
        raise(EventDraft(name: "cost.allowance_out", at: now(), scope: .mac,
                         sentence: "\(PoolWords.runtimeName(entry.runtimeID))’s allowance ran out.", details: details))
    }

    /// An allowance came back: the person said so, or a turn on it worked (042).
    func raiseAllowanceBack(_ entry: PoolEntry, how: String) {
        raise(EventDraft(name: "cost.allowance_back", at: now(), scope: .mac,
                         sentence: "\(PoolWords.runtimeName(entry.runtimeID))’s allowance came back.",
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
        return PoolStatus(settings: pool, rows: rows, switches: switches, titles: titles, at: at)
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
    func broadcastPool() {
        broadcast(DaemonAPI.Notification.poolChanged, poolStatus())
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
    }
}
