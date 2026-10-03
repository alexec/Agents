import Foundation
import AgentsKitCore

/// A project's Dashboard (074): the three tools agents keep tiles with, the person's
/// Hide, Show and Remove, and what every screen reads.
///
/// Tools give atomicity, files give storage (Alex, 2026-10-02). Every write goes through
/// here, inside the actor, so one project's tiles are written one at a time and whole;
/// the files are the project folder's, never a worktree's; nothing is committed.
extension DaemonCore {
    // MARK: Agents' tools

    /// `set_tile`: create or replace a tile the caller keeps.
    public func setTile(_ request: DaemonAPI.SetTileRequest) throws -> String {
        let caller = try dashboardCaller(request.token)
        let project = caller.projectFolder
        try requireFolder(project)
        let check: TileCheck
        switch TileCheck.read(request.arguments) {
        case .success(let read): check = read
        case .failure(let problem): throw dashboardRefusal(problem.message)
        }
        let at = now()
        var state = dashboardStore.state(project)
        let callerKey = caller.id.uuidString
        let recent = (state.sets[callerKey] ?? []).filter { at.timeIntervalSince($0) < 3600 }
        if recent.count >= TileLimits.setsPerHour, let oldest = recent.min() {
            throw dashboardRefusal(TileCheck.lead + "you have set \(TileLimits.setsPerHour) tiles in the last hour, "
                + "the most an agent may; try again after \(DashboardWords.time(oldest.addingTimeInterval(3600))).")
        }

        let keeper = tileKeeper(for: caller)
        let existing = dashboardStore.read(project, check.id)
        var notes: [String] = []
        var record = state.tiles[check.id] ?? DashboardState.TileRecord(made: at)
        if let held = existing?.tile?.keeper, held != keeper {
            guard check.takeOver, canTakeOver(held, by: caller, in: project) else {
                throw dashboardRefusal(TileCheck.lead + "\"\(check.id)\" is kept by \(keeperWords(held, in: project)); "
                    + (check.takeOver
                       ? "it can be taken over only once its keeper is archived or retired, or by the agent continuing its session."
                       : "ask it, or take it over with take_over once it is archived."))
            }
            record.keeperChanges.append(KeeperChange(at: at, from: keeperWords(held, in: project),
                                                     to: keeperWords(keeper, in: project)))
            notes.append("You keep this tile now; it was \(keeperWords(held, in: project))'s.")
        }
        if existing == nil {
            let count = dashboardStore.readTiles(project).count
            guard count < TileLimits.tilesPerProject else {
                throw dashboardRefusal(TileCheck.lead + "this project's Dashboard has \(TileLimits.tilesPerProject) tiles, "
                    + "the most it may; remove one you keep first.")
            }
        }
        if check.tile.type == .number, dashboardStore.historyBytes(project) >= TileLimits.historyBytes {
            throw dashboardRefusal(TileCheck.lead + "this project's Dashboard history on this host is at its 8 MB limit; "
                + "remove a number tile you no longer keep.")
        }

        var tile = check.tile
        tile.keeper = keeper
        // The person's Hide survives the keeper's posts (FR-027).
        tile.hidden = existing?.tile?.hidden
        let size = (try? tile.fileData().count) ?? 0
        guard size <= TileLimits.fileBytes else {
            throw dashboardRefusal(TileCheck.lead + "the tile's file would be \(size / 1024 + 1) KB, over the 8 KB a tile may be.")
        }

        let written: (hash: String, written: Bool)
        do {
            written = try dashboardStore.write(tile, id: check.id, in: project)
        } catch {
            throw dashboardRefusal(TileCheck.lead + "the file could not be written in \(project.path)/.agents/dashboard: "
                + "\(error.localizedDescription)")
        }
        if existing == nil { record.made = state.tiles[check.id]?.made ?? at }
        record.set = at
        record.hash = written.hash
        state.tiles[check.id] = record
        state.sets[callerKey] = recent + [at]
        if let removal = state.removals.removeValue(forKey: check.id),
           at.timeIntervalSince(removal.at) < TileLimits.removalKept {
            notes.append("\(removal.by.prefix(1).uppercased() + removal.by.dropFirst()) removed this tile on "
                + "\(DashboardWords.dayAndTime(removal.at)); posting has put it back. If it is not wanted, "
                + "stop keeping it with remove_tile.")
        }
        state.removals = state.removals.filter { at.timeIntervalSince($0.value.at) < TileLimits.removalKept }
        dashboardStore.save(state, for: project)
        if let number = tile.number {
            dashboardStore.record(number.value, at: at, for: check.id, in: project)
            notes.append("Recorded a point (\(dashboardStore.points(project, check.id).count) kept).")
        }
        if tile.isHidden {
            notes.append("The person has hidden this tile; it is kept up to date out of sight.")
        }
        if !written.written { notes.append("Unchanged; its age is refreshed.") }
        dashboardChanged(project)

        let stored = (try? tile.fileData()).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        return (["Set \"\(check.id)\" on the Dashboard, in .agents/dashboard/\(check.id).json in the project folder:",
                 stored.trimmingCharacters(in: .whitespacesAndNewlines)] + notes).joined(separator: "\n")
    }

    /// `remove_tile`: remove a tile the caller keeps, with its history.
    public func removeTile(_ request: DaemonAPI.RemoveTileRequest) throws -> String {
        let caller = try dashboardCaller(request.token)
        let project = caller.projectFolder
        let id = request.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let found = dashboardStore.read(project, id) else {
            throw dashboardRefusal("Nothing was removed: this project's Dashboard has no tile \"\(id)\".")
        }
        if let held = found.tile?.keeper, held != tileKeeper(for: caller) {
            throw dashboardRefusal("Nothing was removed: \"\(id)\" is kept by \(keeperWords(held, in: project)).")
        }
        forgetTile(id, in: project)
        dashboardChanged(project)
        return "Removed \"\(id)\" and its history from the Dashboard."
    }

    /// `read_dashboard`: every tile in the caller's project, for agents to build on.
    public func readDashboard(_ request: DaemonAPI.DashboardTokenRequest) throws -> String {
        let caller = try dashboardCaller(request.token)
        let snapshot = dashboardSnapshot(caller.projectFolder)
        guard !snapshot.tiles.isEmpty else {
            return "This project's Dashboard has no tiles yet. Keep one with set_tile."
        }
        let mine = tileKeeper(for: caller)
        var blocks: [String] = []
        for view in DashboardModel.ordered(snapshot.tiles) {
            var lines: [String] = []
            guard let tile = view.tile else {
                blocks.append("\(view.id): broken — \(view.problem ?? "unreadable").")
                continue
            }
            let keeperLine = tile.keeper == mine ? "you" : "\(view.keeper.name) (\(view.keeper.kind.rawValue), \(view.keeper.state.rawValue))"
            lines.append("\(view.id) — \(tile.title) [\(tile.type.rawValue)]\(tile.section.map { " in \($0)" } ?? "")")
            lines.append("  value: \(DashboardWords.value(tile))")
            lines.append("  keeper: \(keeperLine); \(DashboardModel.ageWords(view, now: snapshot.now))"
                + (DashboardModel.isStale(view, now: snapshot.now) ? " (stale)" : "")
                + (tile.isHidden ? "; hidden by the person" : "")
                + (view.changedOutside ? "; changed outside Agents" : ""))
            if let source = tile.source { lines.append("  source: \(source)") }
            if !view.recent.isEmpty {
                lines.append("  last points: " + view.recent.map {
                    "\(DashboardModel.numberWords($0.value)) at \(DashboardWords.dayAndTime($0.at))" }.joined(separator: ", "))
            }
            blocks.append(lines.joined(separator: "\n"))
        }
        return blocks.joined(separator: "\n\n")
    }

    // MARK: The person's

    public func dashboardSnapshot(_ folder: URL) -> DashboardSnapshot {
        let project = Project.standardize(folder)
        let state = dashboardStore.state(project)
        let at = now()
        let monthAgo = at.addingTimeInterval(-30 * 86_400)
        let tiles = dashboardStore.readTiles(project).map { found -> TileView in
            let record = state.tiles[found.id]
            let points = found.tile?.type == .number ? dashboardStore.points(project, found.id) : []
            return TileView(id: found.id, tile: found.tile, problem: found.problem,
                            made: record?.made, setAt: record?.set,
                            keeper: keeperView(found.tile?.keeper, in: project),
                            changedOutside: record?.hash != nil && record?.hash != found.hash,
                            points: DashboardStore.downsampled(points, since: monthAgo, limit: TileLimits.pointsSent),
                            recent: Array(points.suffix(TileLimits.recentPoints)),
                            keeperChanges: record?.keeperChanges ?? [])
        }
        return DashboardSnapshot(folder: project, tiles: DashboardModel.ordered(tiles), now: at)
    }

    public func dashboardSummaries() -> [DashboardSummary] {
        allProjects(includeArchived: false).compactMap { project in
            let folder = Project.standardize(project.folder)
            guard FileManager.default.fileExists(atPath: DashboardStore.tilesFolder(folder).path) else { return nil }
            return DashboardModel.summary(dashboardSnapshot(folder))
        }
    }

    /// Hide or Show, in the tile's file (FR-027).
    public func setTileHidden(_ request: DaemonAPI.TileRequest, hidden: Bool) throws {
        let project = Project.standardize(request.folder)
        guard let found = dashboardStore.read(project, request.id), var tile = found.tile else {
            throw dashboardRefusal("This Dashboard has no tile \"\(request.id)\" that can be \(hidden ? "hidden" : "shown").")
        }
        tile.hidden = hidden ? true : nil
        var state = dashboardStore.state(project)
        let written = try dashboardStore.write(tile, id: request.id, in: project)
        // Only a tile this host wrote keeps its record of being ours; a changed-outside
        // one stays marked as it was.
        if state.tiles[request.id]?.hash == found.hash {
            state.tiles[request.id]?.hash = written.hash
            dashboardStore.save(state, for: project)
        }
        dashboardChanged(project)
    }

    /// Remove: the file and its history go; the keeper's next set brings it back, and
    /// is told who removed it and when (FR-028).
    public func removeTileByPerson(_ request: DaemonAPI.TileRequest, from surface: Surface?) throws {
        let project = Project.standardize(request.folder)
        guard dashboardStore.read(project, request.id) != nil else {
            throw dashboardRefusal("This Dashboard has no tile \"\(request.id)\".")
        }
        forgetTile(request.id, in: project)
        var state = dashboardStore.state(project)
        state.removals[request.id] = DashboardState.Removal(at: now(), by: DashboardWords.person(surface))
        dashboardStore.save(state, for: project)
        dashboardChanged(project)
    }

    // MARK: Changes

    /// Tell every screen, at most once a second per project (research R6).
    func dashboardChanged(_ project: URL) {
        guard dashboardBroadcasts[project] == nil else { return }
        dashboardBroadcasts[project] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Self.dashboardBroadcastGap))
            await self?.sendDashboardChanged(project)
        }
    }

    static let dashboardBroadcastGap = 1000

    private func sendDashboardChanged(_ project: URL) {
        dashboardBroadcasts[project] = nil
        broadcast(DaemonAPI.Notification.dashboardChanged,
                  DaemonAPI.DashboardChangedNotification(folder: project,
                                                         summary: DashboardModel.summary(dashboardSnapshot(project))))
    }

    /// A changed path under the project's own `.agents/dashboard/` (a hand edit, a pull)
    /// — never a worktree's copy under `.agents/worktrees/…` (research R7).
    func dashboardFilesChanged(_ changed: [URL], in project: URL) {
        let prefix = DashboardStore.tilesFolder(project).path
        guard changed.contains(where: { $0.path == prefix || $0.path.hasPrefix(prefix + "/") }) else { return }
        dashboardChanged(project)
    }

    /// Fold old points, on the hourly housekeeping tick (FR-020).
    func compactDashboards() {
        let at = now()
        for project in allProjects(includeArchived: true) {
            let folder = Project.standardize(project.folder)
            guard FileManager.default.fileExists(atPath: dashboardStore.folder(for: folder).path) else { continue }
            dashboardStore.compact(folder, now: at)
        }
    }

    /// The agent's session has been read by `reader` with `read_session`: 065's way of
    /// carrying a session on, and what lets the reader take its tiles over (research R1).
    func noteSessionRead(_ read: UUID, by reader: UUID) {
        sessionReads[reader, default: []].insert(read)
    }

    // MARK: Inside

    private func forgetTile(_ id: String, in project: URL) {
        dashboardStore.deleteFile(id, in: project)
        dashboardStore.deletePoints(id, in: project)
        var state = dashboardStore.state(project)
        state.tiles.removeValue(forKey: id)
        dashboardStore.save(state, for: project)
    }

    /// The agent, or the workflow that started it, so every run keeps the same tiles (FR-010).
    func tileKeeper(for agent: Agent) -> TileKeeper {
        if let workflow = agent.startedByWorkflow, agent.startedByAgent == nil { return .workflow(workflow) }
        return .agent(agent.id)
    }

    private func canTakeOver(_ held: TileKeeper, by caller: Agent, in project: URL) -> Bool {
        if let id = held.agentID {
            if retired[id] != nil { return true }
            guard let keeper = agents[id] else { return true }
            if keeper.state == .archived { return true }
            let working: Set<AgentState> = [.starting, .running, .waitingOnUser]
            return sessionReads[caller.id]?.contains(id) == true && !working.contains(keeper.state)
        }
        if let workflow = held.workflow {
            guard workflows[project]?[workflow] != nil else { return true }
            return workflowStore.load().state(folder: project, workflowID: workflow)?.isArchived == true
        }
        return true
    }

    private func keeperView(_ keeper: TileKeeper?, in project: URL) -> KeeperView {
        guard let keeper else { return KeeperView(kind: .agent, id: "", name: "nobody", state: .unknown) }
        if let workflow = keeper.workflow {
            let found = workflows[project]?[workflow]
            let archived = workflowStore.load().state(folder: project, workflowID: workflow)?.isArchived == true
            return KeeperView(kind: .workflow, id: workflow, name: found?.name ?? workflow,
                              state: found == nil ? .unknown : archived ? .archived : .active)
        }
        let id = keeper.agentID
        if let id, let agent = agents[id] {
            return KeeperView(kind: .agent, id: id.uuidString, name: agent.title ?? "Untitled",
                              state: agent.state == .archived ? .archived : .active)
        }
        if let id, let gone = retired[id] {
            return KeeperView(kind: .agent, id: id.uuidString, name: gone.title ?? "Untitled", state: .retired)
        }
        return KeeperView(kind: .agent, id: keeper.agent ?? "", name: "an agent not on this host", state: .unknown)
    }

    private func keeperWords(_ keeper: TileKeeper, in project: URL) -> String {
        let view = keeperView(keeper, in: project)
        return view.kind == .workflow ? "the workflow \u{201C}\(view.name)\u{201D}" : "the agent \u{201C}\(view.name)\u{201D}"
    }

    private func requireFolder(_ project: URL) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: project.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw dashboardRefusal(TileCheck.lead + "the project folder \(project.path) is not there.")
        }
    }

    private func dashboardCaller(_ token: String) throws -> Agent {
        guard let id = appTokens[token], let agent = agents[id] else {
            throw JSONRPCError(code: DaemonAPI.Failure.noSuchAgent, message: LeaseWords.noConversation)
        }
        return agent
    }

    private func dashboardRefusal(_ message: String) -> JSONRPCError {
        JSONRPCError(code: DaemonAPI.Failure.dashboardRefused, message: message)
    }
}

/// The Dashboard's words that are the host's.
enum DashboardWords {
    static func time(_ date: Date) -> String {
        date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
    }

    static func dayAndTime(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated)) + " at " + time(date)
    }

    static func person(_ surface: Surface?) -> String {
        switch surface {
        case .mac?, nil: "the person, on the Mac"
        case .device?: "the person, on a phone, iPad or browser"
        }
    }

    static func value(_ tile: TileFile) -> String {
        switch tile.type {
        case .number:
            guard let number = tile.number else { return "—" }
            return DashboardModel.numberWords(number.value) + (number.unit.map { $0.isEmpty ? "" : " \($0)" } ?? "")
        case .status:
            guard let status = tile.status else { return "—" }
            return "\(status.level.rawValue): \(status.line)" + (status.since.map { " (since \($0))" } ?? "")
        case .table:
            guard let table = tile.table else { return "—" }
            return "\(table.columns.joined(separator: " | ")); \(table.rows.count) rows"
        case .note:
            return tile.note.map { String($0.markdown.prefix(200)) } ?? "—"
        case .link:
            guard let link = tile.link else { return "—" }
            return link.url ?? link.session.map { "session \($0)" } ?? link.file.map { "file \($0)" }
                ?? link.workflow.map { "workflow \($0)" } ?? "—"
        }
    }
}
