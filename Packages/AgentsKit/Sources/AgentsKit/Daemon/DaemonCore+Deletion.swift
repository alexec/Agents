import Foundation
import AgentsKitCore

/// Deleting archived agents (051, #398).
///
/// Archiving says an agent is over. Deleting is what comes after: the person's Delete,
/// or the age rule once it has been archived long enough. Its conversation, record and
/// clean worktree go, and nothing is left: anything that named it says it was deleted.
/// The rule is `RetentionPlan`'s; this is the daemon gathering the facts, acting on the
/// answer and telling the windows.
extension DaemonCore {
    /// For the tests: measure folders some other way.
    func setMeasureFolder(_ measure: @escaping @Sendable (URL) -> Int) {
        measureFolder = measure
        archiveIndex = [:]
    }

    // MARK: Loading

    /// The settings, read once.
    func loadRetentionIfNeeded() {
        guard !retentionIsLoaded else { return }
        retentionIsLoaded = true
        retention = retentionStore.load()
    }

    // MARK: Reading

    /// `retention/state`.
    public func retentionState() -> DaemonAPI.RetentionState {
        loadRetentionIfNeeded()
        let archived = agents.archived.values
        return DaemonAPI.RetentionState(settings: retention.settings,
                                        archivedCount: archived.count,
                                        archivedBytes: archived.reduce(0) { $0 + size(of: $1.id) })
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

    // MARK: Settings

    /// `retention/set` (FR-011). A change that would delete agents at once is only
    /// described until the person confirms it; one that deletes nothing is applied
    /// straight away. Applied, it is saved, checked at once, and told to every window.
    public func setRetention(_ request: DaemonAPI.RetentionSetRequest) async -> DaemonAPI.RetentionSetResult {
        loadRetentionIfNeeded()
        if !request.confirmed {
            let archived = candidates()
            let deleting = Set(await decideWithHolds(archived, settings: request.settings, saneNow: now()))
            if !deleting.isEmpty {
                let bytes = archived.filter { deleting.contains($0.id) }.reduce(0) { $0 + $1.sizeOnDisk }
                return DaemonAPI.RetentionSetResult(
                    applied: false, wouldDelete: DaemonAPI.DeletePreview(count: deleting.count, bytes: bytes))
            }
        }
        retention.settings = request.settings
        saveRetention()
        await checkRetention()
        let state = retentionState()
        broadcast(DaemonAPI.Notification.retentionChanged, state)
        return DaemonAPI.RetentionSetResult(applied: true, state: state)
    }

    /// What keeps each of these agents (051, FR-007, research R7): a window reading it, a
    /// workflow run it belongs to, or work in its worktree. Asked in that order, cheapest
    /// first; git is only asked when nothing else holds it.
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

    /// The rule, with holds asked only of the agents it would pick. Asking every archived
    /// agent's worktree every hour would run git hundreds of times for nothing.
    func decideWithHolds(_ archived: [RetentionPlan.Candidate], settings: RetentionSettings,
                         saneNow: Date) async -> [UUID] {
        let due = Set(RetentionPlan.decide(archived: archived, holds: [:], settings: settings, saneNow: saneNow))
        let holds = await self.holds(for: archived.filter { due.contains($0.id) })
        return RetentionPlan.decide(archived: archived, holds: holds, settings: settings, saneNow: saneNow)
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

    /// Decide, and delete what the rule says.
    public func checkRetention() async {
        loadRetentionIfNeeded()
        let saneNow = retention.clock.tick(now: now(), uptime: uptime)
        let before = retentionState()
        for id in await decideWithHolds(candidates(), settings: retention.settings, saneNow: saneNow) {
            do {
                try await delete(id, because: .age)
            } catch {
                DaemonLog.shared.write("could not delete \(id): \(error)")
            }
        }
        saveRetention()
        saveArchiveIndex()
        let after = retentionState()
        if after != before { broadcast(DaemonAPI.Notification.retentionChanged, after) }
    }

    /// Every archived agent, as the rules see it.
    func candidates() -> [RetentionPlan.Candidate] {
        agents.archived.values.map { agent in
            RetentionPlan.Candidate(id: agent.id, archivedAt: agent.archivedAt ?? now(),
                                    lastActivityAt: agent.lastActivityAt, sizeOnDisk: size(of: agent.id))
        }
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

    // MARK: Deleting

    /// `agents/delete`: the person deleting one archived agent (#398). Refused for an
    /// agent that is not archived, or whose work or workflow still holds it; not for one
    /// that is open, since the person asking is usually the one looking at it.
    public func deleteNow(_ id: UUID) async throws {
        loadRetentionIfNeeded()
        guard let agent = agents[id] else {
            throw JSONRPCError(code: DaemonAPI.Failure.noSuchAgent, message: "That agent is not here.")
        }
        guard agent.state == .archived else {
            throw JSONRPCError(code: DaemonAPI.Failure.deleteRefused, message: DeletionWords.notArchived)
        }
        let candidate = RetentionPlan.Candidate(id: id, archivedAt: agent.archivedAt ?? now(),
                                                lastActivityAt: agent.lastActivityAt, sizeOnDisk: 0)
        if let hold = await holds(for: [candidate])[id], hold != .openInWindow {
            throw JSONRPCError(code: DaemonAPI.Failure.deleteRefused, message: DeletionWords.refusal(hold))
        }
        try await delete(id, because: .person)
        broadcast(DaemonAPI.Notification.retentionChanged, retentionState())
    }

    /// The one path every delete takes: the age rule and the person's.
    ///
    /// The worktree first, by archiving's own rule, while the agent is still here for
    /// that rule to read; then the files; then the agent leaves every list.
    func delete(_ id: UUID, because: DeletedBecause) async throws {
        guard let agent = agents[id], agent.state == .archived else {
            throw JSONRPCError(code: DaemonAPI.Failure.deleteRefused, message: DeletionWords.notArchived)
        }
        DaemonLog.shared.write("deleting \(id) (\(because.rawValue))")
        await removeWorktreeIfDone(archiving: id)
        if let root = agent.worktree?.root, FileManager.default.fileExists(atPath: root.path) {
            DaemonLog.shared.write("deleted \(id) and left its worktree \(root.path)")
        }
        try await store.delete(id)
        raiseAgentEvent("agent.deleted", id, sentence: "was deleted with its conversation.",
                        details: ["because": because.rawValue])
        agents.removeValue(forKey: id)
        archiveIndex.removeValue(forKey: id)
        lastWhole.removeValue(forKey: id)
        stops.removeValue(forKey: id)
        broadcast(DaemonAPI.Notification.agentRemoved, DaemonAPI.AgentRemovedNotification(agentID: id))
        projectChanged(forAgentIn: agent.projectFolder)
    }
}
