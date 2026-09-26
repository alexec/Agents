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
        retired = retiredStore.loadAll()
    }

    // MARK: Reading

    /// `retention/state`.
    public func retentionState() -> DaemonAPI.RetentionState {
        loadRetentionIfNeeded()
        let archived = agents.values.filter { $0.state == .archived }
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

    /// Every tombstone in each project, for the project summaries.
    func tombstonesByProject() -> [URL: [Tombstone]] {
        loadRetentionIfNeeded()
        return Dictionary(grouping: retired.values) { Project.standardize($0.project) }
    }

    // MARK: Settings

    /// `retention/set` (FR-011). A change that would retire agents at once is only
    /// described until the person confirms it; one that retires nothing is applied
    /// straight away. Applied, it is saved, checked at once, and told to every window.
    public func setRetention(_ request: DaemonAPI.RetentionSetRequest) async -> DaemonAPI.RetentionSetResult {
        loadRetentionIfNeeded()
        if !request.confirmed {
            let archived = candidates()
            let preview = RetentionPlan.decide(archived: archived, holds: await holds(for: archived),
                                               settings: request.settings, saneNow: now())
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

    /// What keeps each of these agents past its time (051, FR-007). Nothing yet: the
    /// holds come with US5.
    func holds(for candidates: [RetentionPlan.Candidate]) async -> [UUID: Hold] { [:] }

    func saveRetention() {
        do { try retentionStore.save(retention) } catch {
            DaemonLog.shared.write("retention.json: could not write: \(error.localizedDescription)")
        }
    }

    // MARK: Checking

    /// Thirty seconds after start, then hourly (FR-004). Never before the daemon is
    /// listening: start is not held up by it.
    func startRetentionChecks() {
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
        let decision = RetentionPlan.decide(archived: archived, holds: await holds(for: archived),
                                            settings: retention.settings, saneNow: saneNow)
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
        agents.values.filter { $0.state == .archived }.map { agent in
            RetentionPlan.Candidate(id: agent.id, archivedAt: agent.archivedAt ?? now(),
                                    lastActivityAt: agent.lastActivityAt, sizeOnDisk: size(of: agent.id))
        }
    }

    /// Put each archived agent's note on its record, and only where it changed.
    func noteRetirements(_ notes: [UUID: Retirement]) {
        for agent in agents.values where agent.state == .archived && agent.retirement != notes[agent.id] {
            var noted = agent
            noted.retirement = notes[agent.id]
            changed(noted)
        }
    }

    func saveArchiveIndex() {
        do { try archiveIndexStore.save(archiveIndex, now: now()) } catch {
            DaemonLog.shared.write("archive.json: could not write: \(error.localizedDescription)")
        }
    }

    // MARK: Retiring

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
