import AgentsKitCore
import Foundation

/// The warm pool (#183): runtimes kept running between turns for the replies most likely
/// to come, and runtimes started ahead of a prompt the person is about to send.
///
/// A warm runtime stays in `live`, and the entry in `warm` is what makes it idle: it is
/// not counted by `isHoldingAgents`, the agent's state stays Finished, so neither the
/// helper limits (#64) nor the Mac's wake (024) see it, and the silence watch (#166)
/// watches only turns. Every way out of `live` goes through `forget`, which drops the
/// entry too, so a warm runtime that dies is forgotten quietly and the next prompt
/// starts one as before.
///
/// Every decision is logged as `warm pool:` with its reason, so the rules can be tuned
/// from `daemon.log`.
extension DaemonCore {
    /// The most kept at once: the person's setting, beside the Mac's wake.
    var warmCap: Int {
        guard launcher.keepsRuntimesWarm else { return 0 }
        loadWakeSettingsIfNeeded()
        return wakeSettings.warmRuntimes
    }

    /// At a turn's end: into the pool, or let go as before.
    func keepWarmOrRelease(_ agentID: UUID) async {
        guard live[agentID] != nil else { return await releaseRuntime(for: agentID) }
        guard let agent = agents[agentID] else { return await releaseRuntime(for: agentID) }
        // Ended by the app with the runtime still inside the turn (#139: it did not answer
        // the cancel). It is not idle, and the next prompt must not go to it.
        if let session = live[agentID], endedForTheRuntime.contains(ObjectIdentifier(session)) {
            DaemonLog.shared.write("warm pool: released \(agentID) at turn end: the runtime is still in its turn")
            return await releaseRuntime(for: agentID)
        }
        // A move waiting for the runtime to go (053), and anything but a plain finish:
        // a stop, a limit, a failure. Those are what releasing at once is for.
        if let why = neverWarm(agent) {
            DaemonLog.shared.write("warm pool: released \(agentID) at turn end: \(why)")
            return await releaseRuntime(for: agentID)
        }
        let entry = WarmPool.Entry(since: now())
        let score = WarmPool.score(entry, warmSignals(agent), now: now())
        guard score > 0, warmCap > 0 else {
            DaemonLog.shared.write("warm pool: released \(agentID) at turn end: \(warmCap == 0 ? "the pool is off" : "nobody is expected (\(describe(agent)))")")
            return await releaseRuntime(for: agentID)
        }
        warm[agentID] = entry
        DaemonLog.shared.write("warm pool: pooled \(agentID) score \(Int(score)) (\(describe(agent)))")
        await reviseWarmPool()
    }

    /// Why this agent's runtime must not be kept, or nil.
    func neverWarm(_ agent: Agent) -> String? {
        if agent.pendingMove != nil { return "a move is waiting" }
        if agent.state != .finished { return "it is \(agent.state.rawValue)" }
        if agent.missingFolder != nil { return "its folder is missing" }
        return nil
    }

    /// Re-score every warm runtime and let go of what no longer earns its place: the
    /// zeros, then the lowest until the pool fits its cap.
    func reviseWarmPool() async {
        let at = now()
        let scored = warm.map { id, entry in
            (id: id, score: agents[id].map { WarmPool.score(entry, warmSignals($0), now: at) } ?? 0, since: entry.since)
        }
        for id in WarmPool.releases(scored, cap: warmCap) {
            let score = scored.first { $0.id == id }?.score ?? 0
            let age = Int(at.timeIntervalSince(warm[id]?.since ?? at))
            await releaseWarm(id, because: score <= 0
                ? (age >= Int(WarmPool.ceiling) ? "warm for \(age)s, the ceiling" : "score fell to 0 after \(age)s")
                : "the pool is full and its score \(Int(score)) was lowest")
        }
        tickWhileWarm()
    }

    /// Let one go, if it is still warm, saying why.
    func releaseWarm(_ agentID: UUID, because why: String) async {
        guard warm[agentID] != nil else { return }
        DaemonLog.shared.write("warm pool: released \(agentID): \(why) (\(warm.count - 1) warm)")
        warm.removeValue(forKey: agentID)
        await releaseRuntime(for: agentID)
    }

    /// Every warm runtime of one runtime, after it was updated.
    func releaseWarm(runtimeID: String, because why: String) async {
        for id in warm.keys where agents[id]?.runtimeID == runtimeID {
            await releaseWarm(id, because: why)
        }
    }

    /// The one ticker, while there is a pool: decay and the ceiling act on their own.
    private func tickWhileWarm() {
        if warm.isEmpty {
            warmPoolTicker?.cancel()
            warmPoolTicker = nil
            return
        }
        guard warmPoolTicker == nil else { return }
        warmPoolTicker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self, !Task.isCancelled else { return }
                await self.tickWarmPool()
            }
        }
    }

    private func tickWarmPool() async {
        guard !warm.isEmpty else {
            warmPoolTicker?.cancel()
            warmPoolTicker = nil
            return
        }
        await reviseWarmPool()
    }

    // MARK: What the score is made from

    func warmSignals(_ agent: Agent) -> WarmPool.Signals {
        var signals = WarmPool.Signals()
        for presence in presences.values where presence.watching == agent.id {
            if presence.active { signals.watchedActive = true } else { signals.watched = true }
        }
        signals.needsAnswer = agent.report?.outcome == .needsAnswer
            || elicitations.values.contains { $0.agentID == agent.id }
        signals.unread = agent.isUnread
        signals.parked = agent.parking?.isParked == true
        let prompts = personPromptTimes[agent.id] ?? []
        signals.personsConversation = !prompts.isEmpty
            || (agent.startedByWorkflow == nil && agent.startedByAgent == nil)
        signals.lastPersonPrompt = prompts.last
        signals.typicalGap = WarmPool.typicalGap(prompts)
        if let away = personAwaySince { signals.personAway = now().timeIntervalSince(away) >= WarmPool.awayDrainsAfter }
        return signals
    }

    /// The signals in words, for the log line that says why.
    func describe(_ agent: Agent) -> String {
        let s = warmSignals(agent)
        var words: [String] = []
        if s.watchedActive { words.append("on screen") } else if s.watched { words.append("open") }
        if s.needsAnswer { words.append("needs an answer") }
        if s.unread { words.append("unread") }
        if s.parked { words.append("parked") }
        if !s.personsConversation { words.append(agent.startedByWorkflow != nil ? "a workflow's" : "an agent's") }
        if let last = s.lastPersonPrompt { words.append("last prompt \(Int(now().timeIntervalSince(last)))s ago") }
        if let gap = s.typicalGap { words.append("replies every \(Int(gap))s") }
        if s.personAway { words.append("person away") }
        return words.isEmpty ? "a chat" : words.joined(separator: ", ")
    }

    /// A person's prompt, for how quickly they reply. The last four, and only for agents
    /// still about: bounded by the agents held, and dropped on archive.
    func notePersonPrompt(_ agentID: UUID) {
        var times = personPromptTimes[agentID] ?? []
        times.append(now())
        personPromptTimes[agentID] = Array(times.suffix(4))
        // Bound the whole map too, to the most recently prompted.
        if personPromptTimes.count > 256,
           let oldest = personPromptTimes.min(by: { ($0.value.last ?? .distantPast) < ($1.value.last ?? .distantPast) })?.key {
            personPromptTimes.removeValue(forKey: oldest)
        }
    }

    /// The person left the Mac or came back. Away long enough, and the pool drains to
    /// what is on screen somewhere; the ticker does that, so a glance away keeps it.
    func notePersonAway(_ away: Bool) {
        personAwaySince = away ? (personAwaySince ?? now()) : nil
        if away { tickWhileWarm() }
    }

    // MARK: Reuse

    /// Why a warm runtime cannot take this agent's next turn, or nil if it can: what the
    /// turn would start with now differs from what it was started with (064 FR-012, 054
    /// R12), or its runtime was updated since.
    func warmMismatch(_ agent: Agent) -> String? {
        guard let print = launchPrints[agent.id] else { return "what it started with is unknown" }
        if print != launchPrint(for: agent) { return "what its next turn starts with changed" }
        if agent.runtimeID == RuntimeCatalog.codex.id, let home = locations.personalHome {
            let changes = PersonalDotAgents.codexChanges(home: home, record: .load(from: locations.personalLayout, home: home))
            if !changes.add.isEmpty || !changes.remove.isEmpty { return "Codex plugins changed" }
        }
        if agent.pendingMove != nil { return "a move is waiting" }
        return nil
    }

    /// What a start of this agent's runtime would be given, as one number: where the
    /// runtime is (an update moves `current`), the sandbox, the session's `_meta`
    /// (scoping, plugins, rules), its folders, MCP servers, and the credential lent.
    /// Hashed in memory and never kept, so nothing lent is written anywhere.
    func launchPrint(for agent: Agent) -> Int {
        var hasher = Hasher()
        hasher.combine(agent.runtimeID)
        if let runtime = RuntimeCatalog.runtime(id: agent.runtimeID),
           case .available(let path, _) = discovery.locate(runtime) {
            hasher.combine(URL(filePath: path).resolvingSymlinksInPath().path)
        }
        let sandbox = resolveSandbox(for: agent).choice
        hasher.combine(sandbox)
        hasher.combine(sessionMeta(runtimeID: agent.runtimeID, cwd: agent.cwd,
                                   managesAgents: agent.startedByAgent == nil, sandbox: sandbox))
        hasher.combine(agent.cwd)
        hasher.combine(agent.additionalDirectories)
        hasher.combine(agent.mcpServers)
        if let lent = try? launchEnvironment(for: agent.runtimeID) {
            for key in lent.keys.sorted() {
                hasher.combine(key)
                hasher.combine(lent[key])
            }
        }
        return hasher.finalize()
    }

    // MARK: Warm on intent

    /// `agents/prewarm`: a window opened this session, or somebody is typing in its box.
    /// Answers at once. A runtime already warm has its intent noted; otherwise one is
    /// started behind, without a word in the conversation, and joins the pool. A
    /// window saying so on every keystroke starts one runtime: the debounce is here as
    /// well as in each window.
    public func prewarm(_ request: DaemonAPI.PrewarmRequest) throws {
        guard let agent = agents[request.agentID] else {
            throw JSONRPCError(code: DaemonAPI.Failure.noSuchAgent, message: "That agent is not here.")
        }
        let id = agent.id
        let at = now()
        if var entry = warm[id] {
            entry.intentAt = at
            entry.since = at
            warm[id] = entry
            return
        }
        // Busy, already starting, or nothing to warm.
        guard live[id] == nil, launching[id] == nil, !sending.contains(id), turnTasks[id] == nil,
              Self.mayPrewarm(agent), warmCap > 0 else { return }
        if let last = prewarmedAt[id], at.timeIntervalSince(last) < Self.prewarmDebounce { return }
        prewarmedAt[id] = at
        DaemonLog.shared.write("warm pool: prewarming \(id): \(request.why.rawValue)")
        let stopsBefore = stops[id, default: 0]
        Task { [weak self] in await self?.finishPrewarm(id, stopsBefore: stopsBefore, why: request.why) }
    }

    /// Settled, where it is, with nothing waiting to move it: a finished chat, or one
    /// the person stopped and is coming back to.
    static func mayPrewarm(_ agent: Agent) -> Bool {
        (agent.state == .finished || agent.state == .stopped)
            && agent.pendingMove == nil && agent.missingFolder == nil
    }

    /// One start per session per this long, however often a window asks.
    static let prewarmDebounce: TimeInterval = 20

    private func finishPrewarm(_ id: UUID, stopsBefore: Int, why: DaemonAPI.PrewarmRequest.Why) async {
        guard let agent = agents[id] else { return }
        do {
            _ = try await liveSession(for: agent, quiet: true)
        } catch {
            return
        }
        // A prompt took it as it came up: it is that turn's now.
        guard turnTasks[id] == nil, !sending.contains(id), live[id] != nil else { return }
        guard stops[id, default: 0] == stopsBefore, let now = agents[id], Self.mayPrewarm(now) else {
            DaemonLog.shared.write("warm pool: released \(id) after prewarming: stopped, archived or moved meanwhile")
            return await releaseRuntime(for: id)
        }
        let at = self.now()
        warm[id] = WarmPool.Entry(since: at, intentAt: at)
        DaemonLog.shared.write("warm pool: warmed \(id) on intent (\(why.rawValue)), \(warm.count) warm")
        await reviseWarmPool()
    }
}
