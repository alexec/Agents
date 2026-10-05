import Foundation
import AgentsKitCore

/// Retiring archived agents (051).
///
/// Archiving says an agent is over. Retiring is what comes after: once it has been
/// archived long enough, or the archive takes more room than the person allows, its
/// conversation and record are deleted and a tombstone is left for everything that
/// names it. The rules are `RetentionPlan`'s; this is the daemon gathering the facts,
/// acting on the answer and telling the windows.
extension DaemonCore {
    /// For the tests: measure folders some other way.
    func setMeasureFolder(_ measure: @escaping @Sendable (URL) -> Int) {
        measureFolder = measure
        archiveIndex = [:]
    }

    // MARK: Loading

    /// The settings and the tombstones, read once. Before the agents, so a start can
    /// finish a retire the last daemon was cut off in the middle of.
    func loadRetentionIfNeeded() {
        guard !retentionIsLoaded else { return }
        retentionIsLoaded = true
        retention = retentionStore.load()
        retired = TombstoneTable(retiredStore.loadAll())
        // A new table counts its folders from nothing: the index is made again.
        projectIndexCache = nil
    }

    // MARK: Reading

    /// `retention/state`.
    public func retentionState() -> DaemonAPI.RetentionState {
        loadRetentionIfNeeded()
        let archived = agents.archived.values
        return DaemonAPI.RetentionState(settings: retention.settings,
                                        archivedCount: archived.count,
                                        archivedBytes: archived.reduce(0) { $0 + size(of: $1.id) },
                                        retiredCount: retired.count,
                                        overCap: lastOverCap)
    }

    /// What an archived agent takes on disk: from the index when it has it, measured
    /// when it does not.
    func size(of id: UUID) -> Int {
        if let entry = archiveIndex[id] { return entry.sizeOnDisk }
        let size = measureFolder(locations.agent(id))
        if let agent = agents[id], agent.state == .archived,
           let modified = ArchiveIndex.modifiedAt(locations.record(id)) {
            archiveIndex[id] = ArchiveIndex.Entry(agent: agent, sizeOnDisk: size, fileModifiedAt: modified)
        }
        return size
    }

    /// `agents/retired`: by id, or a project's newest first, or the newest of all.
    public func retiredTombstones(_ request: DaemonAPI.RetiredRequest) -> [Tombstone] {
        loadRetentionIfNeeded()
        let limit = min(max(1, request.limit ?? DaemonAPI.RetiredRequest.limitCeiling),
                        DaemonAPI.RetiredRequest.limitCeiling)
        if let ids = request.ids {
            return ids.prefix(limit).compactMap { retired[$0] }
        }
        let folder = request.folder.map(Project.standardize)
        return retired.values
            .filter { folder == nil || $0.project == folder }
            .sorted { $0.retiredAt > $1.retiredAt }
            .prefix(limit)
            .map { $0 }
    }

    // MARK: Settings

    /// `retention/set` (FR-011). A change that would retire agents at once is only
    /// described until the person confirms it; one that retires nothing is applied
    /// straight away. Applied, it is saved, checked at once, and told to every window.
    public func setRetention(_ request: DaemonAPI.RetentionSetRequest) async -> DaemonAPI.RetentionSetResult {
        loadRetentionIfNeeded()
        if !request.confirmed {
            let archived = candidates()
            let preview = await decideWithHolds(archived, settings: request.settings, saneNow: now())
            if !preview.retire.isEmpty {
                let sizes = Dictionary(archived.map { ($0.id, $0.sizeOnDisk) }, uniquingKeysWith: { a, _ in a })
                let bytes = preview.retire.reduce(0) { $0 + (sizes[$1.id] ?? 0) }
                return DaemonAPI.RetentionSetResult(
                    applied: false, wouldRetire: DaemonAPI.RetirePreview(count: preview.retire.count, bytes: bytes))
            }
        }
        retention.settings = request.settings
        saveRetention()
        await checkRetention()
        let state = retentionState()
        broadcast(DaemonAPI.Notification.retentionChanged, state)
        return DaemonAPI.RetentionSetResult(applied: true, state: state)
    }

    /// What keeps each of these agents past its time (051, FR-007, research R7): a window
    /// reading it, a workflow run it belongs to, or work in its worktree. Asked in that
    /// order, cheapest first; git is only asked when nothing else holds it.
    func holds(for candidates: [RetentionPlan.Candidate]) async -> [UUID: Hold] {
        var holds: [UUID: Hold] = [:]
        let watched = Set(presences.values.compactMap(\.watching)).union(showing.agents)
        let inRuns = Set(workflowRuns.values.flatMap { [$0.agentID, $0.triggeringAgentID].compactMap { $0 } })
        for candidate in candidates {
            let id = candidate.id
            if watched.contains(id) || (lastWhole[id].map { now().timeIntervalSince($0) < Self.letGoAfter } ?? false) {
                holds[id] = .openInWindow
            } else if inRuns.contains(id) {
                holds[id] = .workflowRunning
            } else if await worktreeHoldsWork(of: id) {
                holds[id] = .worktreeHasWork
            }
        }
        return holds
    }

    /// How long an archived agent stays whole after it was last read (FR-025).
    static let letGoAfter: TimeInterval = 10 * 60

    /// The rules, with holds asked only of the agents the rules would pick. Asking every
    /// archived agent's worktree every hour would run git hundreds of times for nothing.
    /// A held agent can leave room under the cap for one that was not picked before, so
    /// this goes round until nothing new is picked.
    func decideWithHolds(_ archived: [RetentionPlan.Candidate], settings: RetentionSettings,
                         saneNow: Date) async -> RetentionPlan.Decision {
        var holds: [UUID: Hold] = [:]
        var asked = Set<UUID>()
        while true {
            let decision = RetentionPlan.decide(archived: archived, holds: holds, settings: settings, saneNow: saneNow)
            let retiring = Set(decision.retire.map(\.id))
            let fresh = archived.filter { !asked.contains($0.id) && retiring.contains($0.id) }
            if fresh.isEmpty { return decision }
            asked.formUnion(fresh.map(\.id))
            holds.merge(await self.holds(for: fresh)) { $1 }
        }
    }

    func saveRetention() {
        do { try retentionStore.save(retention) } catch {
            DaemonLog.shared.write("retention.json: could not write: \(error.localizedDescription)")
        }
    }

    // MARK: The index and slim agents (US6)

    /// How far a record may be newer than its index entry and still be taken from the
    /// index: the entry is made when the agent changes, and the record is written just
    /// after, by the save queue.
    static let indexTolerance: TimeInterval = 5

    /// Bring an archived agent's index entry up to date with it: slim, measured, and
    /// stamped with when its record was last written.
    func indexEntry(for id: UUID) {
        guard let agent = agents[id], agent.state == .archived else {
            archiveIndex.removeValue(forKey: id)
            return
        }
        let size = archiveIndex[id]?.sizeOnDisk ?? measureFolder(locations.agent(id))
        // The wall clock, not `now()`: this is compared with a file's modification date,
        // which the file system stamps in real time whatever clock the daemon was given.
        archiveIndex[id] = ArchiveIndex.Entry(agent: agent, sizeOnDisk: size, fileModifiedAt: Date())
    }

    /// Read an archived agent's lists back from its record, so it can be shown, branched
    /// or brought back (FR-024). It stays whole while it is read, and ten minutes after.
    func makeWhole(_ id: UUID) async {
        guard let agent = agents[id], agent.state == .archived else { return }
        lastWhole[id] = now()
        guard agent.isSlim, let disk = try? await store.load(id).agent,
              let current = agents[id], current.isSlim else { return }
        let whole = current.madeWhole(from: disk)
        agents[id] = whole
        // Whole to whoever shows it, a row to the rest (#203).
        tellChanged(whole, from: current)
    }

    /// Slim again every archived agent nobody has read for ten minutes (FR-025).
    func slimIdle() {
        let watched = Set(presences.values.compactMap(\.watching)).union(showing.agents)
        for (id, agent) in agents.archived where !agent.isSlim && !watched.contains(id) {
            if let read = lastWhole[id], now().timeIntervalSince(read) < Self.letGoAfter { continue }
            agents[id] = agent.slimmed()
            lastWhole.removeValue(forKey: id)
        }
    }

    /// Everything held in memory for an agent while it was live, let go when it is
    /// archived (051, FR-026). Called after `stop`, so nothing here is still in use; the
    /// entries are dropped rather than cancelled, and whatever was already unwinding
    /// finishes on its own. `stops` is kept: it is how that unwinding work knows the
    /// agent was stopped (FR-027). What unarchiving needs is on the record.
    func dropLiveState(for id: UUID) {
        live.removeValue(forKey: id)
        sessionClaims.release(id)
        warm.removeValue(forKey: id)
        launchPrints.removeValue(forKey: id)
        lentPrints.removeValue(forKey: id)
        prewarmedAt.removeValue(forKey: id)
        prewarmQueue.removeAll { $0.id == id }
        personPromptTimes.removeValue(forKey: id)
        eventTasks.removeValue(forKey: id)
        turnTasks.removeValue(forKey: id)
        endWatch(id)
        terminalServices.removeValue(forKey: id)
        shownPlanFiles.removeValue(forKey: id)
        openEventWaits.removeValue(forKey: id)
        openEventWaitStarted.removeValue(forKey: id)
        artifactEdits.removeValue(forKey: id)
        reportedChanges.remove(id)
        shellWatchers.removeValue(forKey: id)
        interrupted.removeValue(forKey: id)
        resuming.remove(id)
        sending.remove(id)
        needsBriefing.remove(id)
        held.remove(id)
        pendingPermissions = pendingPermissions.filter { $0.value.agentID != id }
        elicitations = elicitations.filter { $0.value.agentID != id }
        appTokens = appTokens.filter { $0.value != id }
        // Nothing writes to it now until it is unarchived (#209).
        Task { [store] in await store.closeTranscript(for: id) }
    }

    /// Which of those maps still hold something for this agent. For the test that keeps
    /// the list above honest as the maps grow.
    func liveStateKeys(for id: UUID) -> [String] {
        var held: [String] = []
        if live[id] != nil { held.append("live") }
        if warm[id] != nil { held.append("warm") }
        if launchPrints[id] != nil { held.append("launchPrints") }
        if lentPrints[id] != nil { held.append("lentPrints") }
        if prewarmedAt[id] != nil { held.append("prewarmedAt") }
        if prewarmQueue.contains(where: { $0.id == id }) { held.append("prewarmQueue") }
        if personPromptTimes[id] != nil { held.append("personPromptTimes") }
        if eventTasks[id] != nil { held.append("eventTasks") }
        if turnTasks[id] != nil { held.append("turnTasks") }
        if finishedTurns[id] != nil { held.append("finishedTurns") }
        if terminalServices[id] != nil { held.append("terminalServices") }
        if shownPlanFiles[id] != nil { held.append("shownPlanFiles") }
        if openEventWaits[id] != nil { held.append("openEventWaits") }
        if openEventWaitStarted[id] != nil { held.append("openEventWaitStarted") }
        if artifactEdits[id] != nil { held.append("artifactEdits") }
        if reportedChanges.peek(id) != nil { held.append("reportedChanges") }
        if shellWatchers[id] != nil { held.append("shellWatchers") }
        if interrupted[id] != nil { held.append("interrupted") }
        if resuming.contains(id) { held.append("resuming") }
        if sending.contains(id) { held.append("sending") }
        if needsBriefing.contains(id) { held.append("needsBriefing") }
        if self.held.contains(id) { held.append("held") }
        if pendingPermissions.values.contains(where: { $0.agentID == id }) { held.append("pendingPermissions") }
        if elicitations.values.contains(where: { $0.agentID == id }) { held.append("elicitations") }
        if appTokens.values.contains(id) { held.append("appTokens") }
        return held
    }

    // MARK: Checking

    /// Thirty seconds after start, then hourly (FR-004). Never before the daemon is
    /// listening: start is not held up by it.
    func startRetentionChecks() {
        if slimSweep == nil {
            slimSweep = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(60))
                    guard let self else { return }
                    await self.slimIdle()
                }
            }
        }
        guard retentionTimer == nil else { return }
        retentionTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            while !Task.isCancelled {
                guard let self else { return }
                await self.checkRetention()
                try? await Task.sleep(for: .seconds(60 * 60))
            }
        }
    }

    /// Seconds since this daemon was made, for `RetentionClock`.
    var uptime: TimeInterval {
        let elapsed = ContinuousClock.now - uptimeOrigin
        return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }

    /// Decide, retire what the rules say, and update every archived row's note.
    public func checkRetention() async {
        loadRetentionIfNeeded()
        let saneNow = retention.clock.tick(now: now(), uptime: uptime)
        let before = retentionState()
        let archived = candidates()
        let decision = await decideWithHolds(archived, settings: retention.settings, saneNow: saneNow)
        for retiring in decision.retire {
            do {
                try await retire(retiring.id, because: retiring.because)
            } catch {
                DaemonLog.shared.write("could not retire \(retiring.id): \(error)")
            }
        }
        lastOverCap = decision.overCap
        noteRetirements(decision.notes)
        saveRetention()
        saveArchiveIndex()
        let after = retentionState()
        if after != before { broadcast(DaemonAPI.Notification.retentionChanged, after) }
        // The Dashboards' points fold on the same hourly tick (074 FR-020).
        compactDashboards()
    }

    /// A heavy archiving day can cross the cap well before the hourly check, so an
    /// archive asks for one, at most once a minute and only when there is a cap to
    /// cross. Never for the agent just archived: it is on its first day.
    func checkSoonAfterArchiving() {
        loadRetentionIfNeeded()
        guard retention.settings.cap.bytes != nil else { return }
        if let last = lastArchiveCheck, now().timeIntervalSince(last) < 60 { return }
        lastArchiveCheck = now()
        Task { [weak self] in await self?.checkRetention() }
    }

    /// Every archived agent, as the rules see it.
    func candidates() -> [RetentionPlan.Candidate] {
        agents.archived.values.map { agent in
            RetentionPlan.Candidate(id: agent.id, archivedAt: agent.archivedAt ?? now(),
                                    lastActivityAt: agent.lastActivityAt, sizeOnDisk: size(of: agent.id))
        }
    }

    /// Put each archived agent's note on its record, and only where it changed.
    ///
    /// Each project is told once at the end rather than once per agent: a settings change
    /// can note thousands (#164). The agents themselves are not told about one by one
    /// (#203): that re-sent every archived agent to every client, which filed each one it
    /// had let go of. A row on screen reads its note when its list is next read.
    func noteRetirements(_ notes: [UUID: Retirement]) {
        let noting = agents.archived.values.filter { $0.retirement != notes[$0.id] }
        guard !noting.isEmpty else { return }
        heldProjectChanges = []
        for agent in noting {
            var noted = agent
            noted.retirement = notes[agent.id]
            changed(noted, tellingClients: false)
        }
        let held = heldProjectChanges ?? []
        heldProjectChanges = nil
        for folder in held { projectChanged(forAgentIn: folder) }
    }

    func saveArchiveIndexSoon() {
        guard indexSave == nil else { return }
        indexSave = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            await self?.flushArchiveIndex()
        }
    }

    func flushArchiveIndex() {
        indexSave = nil
        saveArchiveIndex()
    }

    /// Write `archive.json`, when the index changed since it was last written or read.
    func saveArchiveIndex() {
        guard archiveIndexChanged else { return }
        do {
            try archiveIndexStore.save(archiveIndex, now: now())
            archiveIndexChanged = false
        } catch {
            DaemonLog.shared.write("archive.json: could not write: \(error.localizedDescription)")
        }
    }

    // MARK: Retiring

    /// `agents/retire`: the person retiring one archived agent now (051, US7). Unconfirmed,
    /// it says how much that frees. Refused for an agent that is not archived, or whose
    /// work or workflow still holds it; not for one that is open, since the person asking
    /// is usually the one looking at it.
    public func retireNow(_ request: DaemonAPI.RetireRequest) async throws -> DaemonAPI.RetirePreview {
        loadRetentionIfNeeded()
        let id = request.agentID
        if agents[id] == nil, let tombstone = retired[id] {
            throw JSONRPCError(code: DaemonAPI.Failure.agentRetired, message: RetirementWords.retiredSentence(tombstone))
        }
        guard let agent = agents[id] else {
            throw JSONRPCError(code: DaemonAPI.Failure.noSuchAgent, message: "That agent is not here.")
        }
        guard agent.state == .archived else {
            throw JSONRPCError(code: DaemonAPI.Failure.retireRefused, message: RetirementWords.notArchived)
        }
        let candidate = RetentionPlan.Candidate(id: id, archivedAt: agent.archivedAt ?? now(),
                                                lastActivityAt: agent.lastActivityAt, sizeOnDisk: size(of: id))
        if let hold = await holds(for: [candidate])[id], hold != .openInWindow {
            throw JSONRPCError(code: DaemonAPI.Failure.retireRefused, message: RetirementWords.refusal(hold))
        }
        let preview = DaemonAPI.RetirePreview(count: 1, bytes: candidate.sizeOnDisk)
        guard request.confirmed else { return preview }
        try await retire(id, because: .person)
        let state = retentionState()
        broadcast(DaemonAPI.Notification.retentionChanged, state)
        return preview
    }

    /// The one path every retire takes: the check, a change of setting, and Retire now.
    ///
    /// The tombstone is written and synced first, and nothing is deleted if it cannot
    /// be (FR-017). Then the worktree, by archiving's own rule, while the agent is still
    /// here for that rule to read; then the files; then the agent leaves every list.
    func retire(_ id: UUID, because: RetiredBecause) async throws {
        guard let agent = agents[id], agent.state == .archived else {
            throw JSONRPCError(code: DaemonAPI.Failure.retireRefused, message: RetirementWords.notArchived)
        }
        DaemonLog.shared.write("retiring \(id) (\(because.rawValue))")
        let tombstone = Tombstone(from: agent, retiredAt: now(), because: because)
        try retiredStore.append(tombstone)
        retired[id] = tombstone
        raiseAgentEvent("agent.retired", id, sentence: "was retired and its conversation deleted.",
                        details: ["because": because.rawValue])
        await removeWorktreeIfDone(archiving: id)
        if let root = agent.worktree?.root, FileManager.default.fileExists(atPath: root.path) {
            // The tombstone keeps where it is, and list_sessions names it from there (#211).
            DaemonLog.shared.write("retired \(id) and left its worktree \(root.path)")
        }
        do {
            try await store.deleteRetired(id)
        } catch {
            // The tombstone is written, so the next start finishes this.
            DaemonLog.shared.write("retired \(id) but could not delete all of it yet: \(error)")
        }
        agents.removeValue(forKey: id)
        archiveIndex.removeValue(forKey: id)
        lastWhole.removeValue(forKey: id)
        stops.removeValue(forKey: id)
        broadcast(DaemonAPI.Notification.agentRemoved, DaemonAPI.AgentRemovedNotification(agentID: id))
        projectChanged(forAgentIn: agent.projectFolder)
    }
}
