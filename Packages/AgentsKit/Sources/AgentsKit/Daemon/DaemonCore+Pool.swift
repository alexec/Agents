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
            await record(.runtimeNote(PoolWords.ranOut(agent.runtimeID, returnsAt: state.returnsAt, now: at)), for: agentID)
            reason = .allowanceSpent
        case .creditGone:
            state.markOut(.creditUsedUp, until: nil, payment: entry.payment, now: at, from: .words)
            setAllowanceState(state)
            await record(.runtimeNote(PoolWords.creditGone(agent.runtimeID)), for: agentID)
            reason = .allowanceSpent
        case .overage(let resetsAt):
            state.markOut(.overage, until: resetsAt, payment: entry.payment, now: at, from: .overageReport)
            setAllowanceState(state)
            await record(.runtimeNote(PoolWords.overageBegan(agent.runtimeID)), for: agentID)
            // The turn itself may have worked; the next one does not go here.
            if reason == .endTurn { return false }
            reason = .allowanceSpent
        case .rateLimited(let retryAfter):
            let attempt = rateLimitAttempts[agentID, default: 0]
            let retryAt = retryAfter ?? at.addingTimeInterval(rateLimitPolicy.delay(forAttempt: attempt))
            if state.rateLimited(now: at, retryAt: retryAt, payment: entry.payment, policy: rateLimitPolicy) {
                setAllowanceState(state)
                rateLimitAttempts[agentID] = nil
                await record(.runtimeNote(PoolWords.stillRateLimited(agent.runtimeID)), for: agentID)
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
