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

    /// The credential an agent's runtime runs on: its own sign-in, on an allowance,
    /// except Gemini, which only ever runs on a key (046).
    func poolEntry(for agent: Agent) -> PoolEntry {
        Self.ownEntry(runtimeID: agent.runtimeID)
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

    /// The credential a key is for (065: every runtime is tracked).
    func entry(forKey key: String) -> PoolEntry {
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
            try allowanceStore.saveAllowances(allowances.values.sorted { $0.credentialKey < $1.credentialKey })
            broadcastAllowances()
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
        if let model = currentModel(of: agent) { state.clearModels { $0.model == model.value } }
        if let rateLimit = latestRateLimit[agentID] { state.lastRateLimit = rateLimit }
        if state != before { setAllowanceState(state) }
        if before.isOut, !state.isOut { raiseAllowanceBack(entry, how: "worked", after: before) }
    }

    /// A failed runtime is marked out even when the failure was not a quota error.
    /// A recognised spent allowance already has its more specific out state.
    ///
    /// A provider's failure (#140) is the model's, not the runtime's: the model the
    /// agent was on is marked, and the runtime's other models stay in. With no model
    /// to charge it to, nothing is marked, since a provider being down says nothing
    /// about the runtime.
    func runtimeFailed(agentID: UUID, error: (any Error)? = nil, words: String? = nil) {
        guard let agent = agents[agentID] else { return }
        let provider = (error as? JSONRPCError).map(ProviderFailure.recognises) == true
            || words.map(ProviderFailure.recognises(words:)) == true
        guard provider else { return markRuntimeFailed(poolEntry(for: agent)) }
        guard let model = currentModel(of: agent) else {
            DaemonLog.shared.write("agent \(agentID): \(agent.runtimeID)'s provider failed on a model not known; nothing marked")
            return
        }
        var state = allowanceState(for: poolEntry(for: agent))
        guard state.markModelFailed(model.value, name: model.name, now: now()) else { return }
        setAllowanceState(state)
        DaemonLog.shared.write("agent \(agentID): \(agent.runtimeID)'s provider failed on \(model.value); the model is marked, not the runtime")
    }

    /// A turn is answering (#140): its tool calls are coming back. A runtime out because
    /// it failed is back now, not at the turn's end, so the agent proving it works can
    /// start a helper on it in the same turn; and the model it is on is no longer out.
    func runtimeAnswering(agentID: UUID) {
        guard let agent = agents[agentID] else { return }
        let entry = poolEntry(for: agent)
        // Most calls find nothing to do: no state, or nothing out.
        guard let before = allowances[AllowanceState.credentialKey(for: entry)],
              before.isOut || before.modelsOut != nil else { return }
        var state = before
        let back = state.answering(now: now())
        if let model = currentModel(of: agent) { state.clearModels { $0.model == model.value } }
        guard state != before else { return }
        setAllowanceState(state)
        if back { raiseAllowanceBack(entry, how: "answering", after: before) }
    }

    /// The model an agent is on, as its runtime's model menu has it: the value and the
    /// name the menu shows. Nil when the runtime has no model menu.
    func currentModel(of agent: Agent) -> (value: String, name: String?)? {
        guard let option = WorkflowSettings.modelOption(in: agent.advertisedOptions),
              let value = agent.startOptions.values[option.id] ?? option.currentValue,
              let model = value.stringValue else { return nil }
        return (model, option.options?.first { $0.value == value }?.name)
    }

    func runtimeFailed(runtimeID: String) {
        markRuntimeFailed(Self.ownEntry(runtimeID: runtimeID))
    }

    /// Any runtime (065): the four-hour check brings it back.
    private func markRuntimeFailed(_ entry: PoolEntry) {
        var state = allowanceState(for: entry)
        guard state.markFailed(now: now()) else { return }
        setAllowanceState(state)
        raiseAllowanceOut(entry, state: state, reason: "runtime failed")
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
            let wasOut = allowances[state.credentialKey]?.isOut ?? false
            allowances[state.credentialKey] = state
            changed = true
            let entry = entry(forKey: state.credentialKey)
            if !wasOut, state.isOut { raiseAllowanceOut(entry, state: state, reason: "learned from another host") }
            if wasOut, !state.isOut { raiseAllowanceBack(entry, how: "another host") }
        }
        guard changed else { return false }
        do {
            try allowanceStore.saveAllowances(allowances.values.sorted { $0.credentialKey < $1.credentialKey })
        } catch {
            DaemonLog.shared.write("allowances could not be written: \(error)")
        }
        broadcastAllowances()
        return true
    }

    /// The shared allowances as this daemon knows them, for carrying to another.
    public func sharedAllowances() -> [AllowanceState] {
        allowances.values.filter(\.isShared).sorted { $0.credentialKey < $1.credentialKey }
    }

    // MARK: Waits left from 052 (US4)

    /// A wait saved by a 052 build: cleared at launch and never resumed (065). Kept while
    /// 052 is after the #58 cut-off (051). The
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
        broadcastAllowances()
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

    // MARK: Every runtime's state (065)

    /// Every runtime's state (065, US4): a row for each runtime this Mac
    /// finds, and one for any other credential with a state. A runtime nothing has
    /// happened to is available. Alphabetical by runtime name (#154), each runtime's own
    /// sign-in before its other credentials.
    public func runtimeAllowances() -> RuntimeAllowances {
        let at = now()
        var own: [String] = []
        for runtime in RuntimeCatalog.builtIn {
            if case .missing = discovery.locate(runtime) { continue }
            own.append(AllowanceState.credentialKey(for: Self.ownEntry(runtimeID: runtime.id)))
        }
        let others = allowances.keys.sorted().filter { !own.contains($0) }
        let byRuntime = Dictionary(grouping: own + others) { entry(forKey: $0).runtimeID }
        let keys = RuntimeCatalog.sortedByName(ids: Array(byRuntime.keys)).flatMap { byRuntime[$0] ?? [] }
        let rows = keys.map { key -> RuntimeAllowances.Row in
            let entry = entry(forKey: key)
            var state = allowances[key] ?? AllowanceState(credentialKey: key, entryID: entry.id, since: at)
            state.settle(now: at)
            return RuntimeAllowances.Row(credentialKey: key, state: state, unusable: unusable(entry))
        }
        return RuntimeAllowances(rows: rows, at: at, shared: sharedAllowances())
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

    /// Tell every window a runtime's state changed (065).
    ///
    /// At most once a second: a change inside the second after the last one is held,
    /// and the one broadcast at the end of it carries the state as it is then.
    func broadcastAllowances() {
        let clock = ContinuousClock()
        if let last = allowanceBroadcastAt, clock.now - last < Self.allowanceBroadcastGap {
            guard !allowanceBroadcastHeld else { return }
            allowanceBroadcastHeld = true
            let wait = Self.allowanceBroadcastGap - (clock.now - last)
            Task {
                try? await Task.sleep(for: wait)
                self.sendHeldAllowanceBroadcast()
            }
            return
        }
        allowanceBroadcastAt = clock.now
        broadcast(DaemonAPI.Notification.runtimesAllowancesChanged, runtimeAllowances())
    }

    static let allowanceBroadcastGap: Duration = .seconds(1)

    private func sendHeldAllowanceBroadcast() {
        allowanceBroadcastHeld = false
        allowanceBroadcastAt = ContinuousClock().now
        broadcast(DaemonAPI.Notification.runtimesAllowancesChanged, runtimeAllowances())
    }

    /// The allowances' clocks, on the workflow heartbeat (no timer of its own): short
    /// rate limits expire.
    func settleAllowanceClocks(now at: Date) {
        var changed = false
        for key in Array(allowances.keys) {
            guard var state = allowances[key],
                  state.isOut || state.status != .available || state.modelsOut != nil else { continue }
            let wasOut = state.isOut
            guard state.settle(now: at) else { continue }
            allowances[key] = state
            changed = true
            if wasOut, !state.isOut { raiseAllowanceBack(entry(forKey: key), how: "time") }
        }
        guard changed else { return }
        do {
            try allowanceStore.saveAllowances(allowances.values.sorted { $0.credentialKey < $1.credentialKey })
        } catch {
            DaemonLog.shared.write("allowances could not be written: \(error)")
        }
        broadcastAllowances()
    }

    /// Check out credentials every four hours. The retry date is only permission to
    /// ask: it never makes an unverified runtime usable by itself.
    func checkDueAllowances(now at: Date) {
        // Every credential with a state, each once.
        var seen: Set<String> = []
        let entries = allowances.keys.sorted().map { entry(forKey: $0) }
            .filter { seen.insert(AllowanceState.credentialKey(for: $0)).inserted }
        for entry in entries {
            let key = AllowanceState.credentialKey(for: entry)
            if var state = allowances[key],
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
        let passed = await probeAllowance(runtimeID: entry.runtimeID,
                                          skipping: Set(expected.modelsOut(now: now()).map(\.model)))
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
    /// A model a provider failed on is skipped (#140): its outage is not the runtime's.
    private func probeAllowance(runtimeID: String, skipping: Set<String> = []) async -> Bool {
        var session: ACPSession?
        var chosen: [String] = []
        do {
            let (made, _) = try await handshakeOnly(runtimeID: runtimeID)
            session = made
            defer { Task { await made.end(gracePeriod: .seconds(1)) } }
            // From the handshake on, not only around the prompt (#166): a session or an
            // option that never answers held `allowanceChecks` for good, and the runtime
            // was never checked again until a restart. The handshake has its own deadline.
            let timeout = Task {
                try? await Task.sleep(for: .seconds(90))
                if !Task.isCancelled { await made.end(gracePeriod: .seconds(1)) }
            }
            defer { timeout.cancel() }
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
                DaemonLog.shared.write("availability check for \(runtimeID): failed, no read-only mode to check in")
                return false
            }
            if let model = WorkflowSettings.modelOption(in: options),
               let choice = Self.probeModel(in: (model.options ?? []).filter {
                   !skipping.contains($0.value.stringValue ?? "")
               }) {
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
            let answer = try await made.prompt("Reply with OK. Do not use tools or edit files.")
            await made.end(gracePeriod: .seconds(1))
            let reply = await replies.value.trimmingCharacters(in: .whitespacesAndNewlines)
            let recognition = LimitRecognition.classify(failure: answer.failure,
                                                        runtimeError: answer.runtimeError?.sentence ?? reply,
                                                        runtimeID: runtimeID, rateLimit: answer.rateLimit)
            let passed = answer.reason == .endTurn && answer.failure == nil && answer.runtimeError == nil
                && recognition == .none && answer.rateLimit?.isRejected != true
                && ["ok", "ok."].contains(reply.lowercased())
            DaemonLog.shared.write("availability check for \(runtimeID): \(passed ? "passed" : "failed") "
                                   + "(\(chosen.joined(separator: ", ")); reply \(reply.prefix(80).debugDescription))")
            return passed
        } catch {
            DaemonLog.shared.write("availability check failed for \(runtimeID): \(error)")
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

    /// Every credential's state, for the Agent Runtimes page and for tests.
    public func allowanceStates() -> [AllowanceState] {
        allowances.values.sorted { $0.credentialKey < $1.credentialKey }
    }

    /// For tests: shorter waits between rate-limit retries.
    func useRateLimitPolicy(_ policy: RateLimitPolicy) {
        rateLimitPolicy = policy
    }

    /// The plan window a runtime reported during a turn (R2): kept for the turn's end,
    /// and on the credential for the Agent Runtimes page.
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

    /// Keep what a runtime said is left of its plan window, for the Agent Runtimes page. The
    /// same reading again is not written until it is five minutes older, since Claude
    /// repeats it on every `usage_update`.
    func noteReading(_ reading: AllowanceReading, for entry: PoolEntry) {
        var state = allowanceState(for: entry)
        if let before = state.reading, before.sameAs(reading),
           reading.at.timeIntervalSince(before.at) < Self.readingKeptFor { return }
        state.reading = reading
        setAllowanceState(state)
    }

    /// How long a reading asked for stands before it is asked for again.
    static let readingKeptFor: TimeInterval = 300

    /// Ask each runtime that can say what is left of its plan, where the last answer is
    /// older than `readingKeptFor`. Grok is the one that can be asked; Claude says it
    /// during turns, unasked. Each ask starts the runtime for a moment, as signing in
    /// does. Runs behind Agent Runtimes: the pane draws what is known now, and the
    /// answer arrives as `runtimes/allowancesChanged`.
    func measureAllowances() async {
        let at = now()
        let asked = [Self.ownEntry(runtimeID: RuntimeCatalog.grok.id)].filter { entry in
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
