import AgentsKitCore
import Foundation

/// The app-owned files in a project's `.agents` wait for the person's OK when changed
/// outside the app (#502): `project.json` (helper limits, disk lines) and `pins.json`.
///
/// An agent can write either by a shell command, which no permission request sees, and
/// what it wrote took effect at once. So the last approved copy of each is kept here,
/// outside the project, and a file that differs from it is not used: the daemon goes on
/// with the copy until the person keeps the change or undoes it.
///
/// Who approves without a click:
/// - the app's own writes (Project Settings, the pin tools, Pin and Unpin), as they are made;
/// - whatever is there the first time the app sees the file;
/// - a change made while no turn is running in the project, which is the person's own
///   (an editor, a terminal) — unless what is on disk is what the last commit holds, which
///   is a merge, pull or branch switch, and waits however it arrived.
///
/// A change seen while turns are running names those agents. It is seen by the project's
/// watch, by any read, and at the end of every turn, so a change made during a turn and
/// first noticed after it still names the agent whose turn it was.
extension DaemonCore {
    var guardedFileStore: GuardedFileStore { GuardedFileStore(file: locations.guardedFiles) }

    func guardedRecords() -> GuardedFileRecords {
        if let guardedRecordsCache { return guardedRecordsCache }
        let records = guardedFileStore.load()
        guardedRecordsCache = records
        return records
    }

    private func saveGuardedRecords(_ records: GuardedFileRecords, replacing: Bool = false) {
        var records = records
        keepQuietly("approved project files") { try guardedFileStore.save(records, replacing: replacing) }
        if replacing { records.unreadable = false }
        if records.approvalsBegan == nil { records.approvalsBegan = Date() }
        guardedRecordsCache = records
    }

    /// The file on disk: its digest and bytes, read again only when its stamp moves.
    func guardedDiskRead(_ file: GuardedFile, in project: URL) -> (digest: String?, data: Data?) {
        let url = file.url(in: project)
        let stamp = DigestStamp(url.path(percentEncoded: false))
        if let known = guardedDisk[url.path], known.stamp == stamp { return (known.digest, known.data) }
        guard stamp != nil, let data = try? Data(contentsOf: url) else {
            guardedDisk[url.path] = (nil, nil, nil)
            return (nil, nil)
        }
        let digest = ContentDigest.sha256(data)
        if DigestStamp(url.path(percentEncoded: false)) == stamp { guardedDisk[url.path] = (stamp, digest, data) }
        return (digest, data)
    }

    /// What the app uses of `file`: the file on disk when it is the approved one, or the
    /// approved copy while a change waits. `onDisk` says which, so a caller that reads the
    /// file its own way (the pins' unreadable-file handling) can still do so.
    func guardedContent(_ file: GuardedFile, in folder: URL) -> (data: Data?, onDisk: Bool) {
        let project = Project.standardize(folder)
        let disk = guardedDiskRead(file, in: project)
        var records = guardedRecords()
        guard let state = records.state(project, file) else {
            if records.unreadable {
                markGuardedChanges(in: project, witness: nil)
                return (nil, disk.digest == nil)
            }
            // The first time: approved as it stands.
            records.update(project, file) {
                $0.approvedDigest = disk.digest
                $0.approvedContent = disk.data
            }
            saveGuardedRecords(records)
            return (disk.data, true)
        }
        if state.approvedDigest == disk.digest {
            if state.pending != nil {
                // Put back by hand, or by the agent that changed it.
                records.update(project, file) { $0.pending = nil }
                saveGuardedRecords(records)
                guardedFilesMoved(project)
            }
            return (disk.data, true)
        }
        guard state.pending == nil || state.pending?.digest != disk.digest else { return (state.approvedContent, false) }
        // Not seen yet: a change with no turn running and no git may be approved here and now.
        checkGuardedFiles(in: project)
        let settled = guardedRecords().state(project, file)
        if settled?.approvedDigest == disk.digest { return (disk.data, true) }
        return (settled?.approvedContent, false)
    }

    /// Whether `file` is the approved one, nothing waiting: the app writes it only then,
    /// since its write would otherwise take in, and approve, a change nobody kept.
    func guardedFileIsSettled(_ file: GuardedFile, in project: URL) -> Bool {
        let project = Project.standardize(project)
        guard let state = guardedRecords().state(project, file) else { return !guardedRecords().unreadable }
        return state.pending == nil && state.approvedDigest == guardedDiskRead(file, in: project).digest
    }

    /// The refusal for an app write while a change waits.
    func guardedRefusal(_ file: GuardedFile, lead: String) -> String {
        lead + "\(file.path) was changed outside the app and is waiting for the person to keep or undo the change "
            + "in Project Settings."
    }

    /// The app wrote `file` (or took it away): what is there now is approved.
    func approveGuardedWrite(_ file: GuardedFile, in folder: URL) {
        let project = Project.standardize(folder)
        let disk = guardedDiskRead(file, in: project)
        var records = guardedRecords()
        if let state = records.state(project, file), state.approvedDigest == disk.digest, state.pending == nil { return }
        records.update(project, file) {
            $0.approvedDigest = disk.digest
            $0.approvedContent = disk.data
            $0.pending = nil
        }
        saveGuardedRecords(records)
    }

    /// The agents with a turn running in the project.
    func agentsWithTurns(in project: URL) -> [Agent] {
        allAgents(includeArchived: false).filter {
            Project.standardize($0.projectFolder) == project
                && (turnTasks[$0.id] != nil || $0.state.hasTurnInFlight)
        }
    }

    /// A turn ended: a change to a guarded file not yet seen was this turn's, or another
    /// still running's.
    func guardedTurnEnded(_ agentID: UUID) {
        guard let agent = agents[agentID] else { return }
        markGuardedChanges(in: Project.standardize(agent.projectFolder), witness: agent)
    }

    /// Look for changes now: from the project's watch, and from a read that found one.
    func checkGuardedFiles(in folder: URL) {
        let project = Project.standardize(folder)
        let idle = markGuardedChanges(in: project, witness: nil)
        guard !idle.isEmpty else { return }
        guard !guardedSettling.contains(project) else {
            guardedSettleAgain.insert(project)
            return
        }
        guardedSettling.insert(project)
        Task { await self.settleIdleGuardedChanges(in: project) }
    }

    /// Every guarded file that differs from its approved copy and is not yet waiting
    /// becomes a waiting change when any turn is running in the project (or `witness`'s
    /// just ended), naming them. Returns the ones changed with no turn running, for
    /// `settleIdleGuardedChanges`.
    @discardableResult
    func markGuardedChanges(in project: URL, witness: Agent?) -> [GuardedFile] {
        var records = guardedRecords()
        var idle: [GuardedFile] = []
        var marked = false
        var running: [Agent]?
        for file in GuardedFile.allCases {
            let disk = guardedDiskRead(file, in: project)
            let state = records.state(project, file)
            if let state, state.approvedDigest == disk.digest { continue }
            // A file first seen is approved by its first read, not here.
            if state == nil, !records.unreadable { continue }
            // Already waiting, as it is: whoever's turn ends now did not make it.
            if let pending = state?.pending, pending.digest == disk.digest { continue }
            if running == nil { running = agentsWithTurns(in: project) }
            var witnesses = running ?? []
            if let witness, !witnesses.contains(where: { $0.id == witness.id }) { witnesses.append(witness) }
            if witnesses.isEmpty {
                if records.unreadable, state?.pending == nil {
                    records.update(project, file) { $0.pending = .init(digest: disk.digest, since: now()) }
                    marked = true
                } else if Self.isInRepository(project) {
                    idle.append(file)
                } else {
                    // No git to have brought it: the person's own, approved now.
                    records.update(project, file) {
                        $0.approvedDigest = disk.digest
                        $0.approvedContent = disk.data
                        $0.pending = nil
                    }
                    marked = true
                }
                continue
            }
            records.update(project, file) { state in
                var pending = state.pending ?? .init(digest: disk.digest, since: now())
                if pending.digest != disk.digest { pending.digest = disk.digest }
                for agent in witnesses where !pending.changedByIDs.contains(agent.id) {
                    pending.changedByIDs.append(agent.id)
                    pending.changedBy.append(agent.title ?? "Untitled")
                }
                if pending != state.pending {
                    state.pending = pending
                    marked = true
                }
            }
        }
        if marked {
            saveGuardedRecords(records)
            guardedFilesMoved(project)
        }
        return idle
    }

    /// Changes made with no turn running: the person's, approved; or, when the file is
    /// what the last commit holds, a merge's or pull's, which waits.
    func settleIdleGuardedChanges(in project: URL) async {
        repeat {
            guardedSettleAgain.remove(project)
            for file in markGuardedChanges(in: project, witness: nil) {
                let disk = guardedDiskRead(file, in: project)
                let fromGit = await Self.isCommitted(disk.data, file, in: project)
                // Whatever moved during the wait is looked at again.
                let after = guardedDiskRead(file, in: project)
                var records = guardedRecords()
                guard after.digest == disk.digest, let state = records.state(project, file),
                      state.approvedDigest != after.digest, state.pending?.digest != after.digest,
                      agentsWithTurns(in: project).isEmpty else { continue }
                records.update(project, file) {
                    if fromGit {
                        $0.pending = .init(digest: after.digest, since: now(), byGit: true)
                    } else {
                        $0.approvedDigest = after.digest
                        $0.approvedContent = after.data
                        $0.pending = nil
                    }
                }
                saveGuardedRecords(records)
                guardedFilesMoved(project)
            }
        } while guardedSettleAgain.contains(project)
        guardedSettling.remove(project)
    }

    /// Whether the project is in a git repository, at its top or below it.
    static func isInRepository(_ project: URL) -> Bool {
        var folder = project.standardizedFileURL
        while true {
            if GitStamp.gitDirectory(of: folder) != nil { return true }
            let parent = folder.deletingLastPathComponent()
            if parent.path == folder.path { return false }
            folder = parent
        }
    }

    /// Whether `data` is what the project's HEAD holds for `file`: it came by git.
    static func isCommitted(_ data: Data?, _ file: GuardedFile, in project: URL) async -> Bool {
        guard let data,
              let outcome = try? await GitChanges.run(["show", "HEAD:./" + file.path], in: project) else { return false }
        return Data(outcome.output.utf8) == data
    }

    /// What every screen and every reader of the files knows is read again.
    func guardedFilesMoved(_ project: URL) {
        let limitsBefore = projectConfigCache[project] ?? nil
        let diskBefore = diskSpaceConfigCache[project] ?? nil
        projectConfigCache[project] = nil
        diskSpaceConfigCache[project] = nil
        pinsCache[project] = nil
        if configuredDiskSpace(in: project) != diskBefore { scheduleDiskCheck() }
        if configuredHelperLimits(in: project) != limitsBefore { checkQueueSoon(in: project) }
        if let summary = projectSummary(for: project) { sendProject(summary) }
        pinsChanged(project)
    }

    /// The waiting changes, for the project's summary.
    func guardedChanges(in project: URL) -> [GuardedChange]? {
        let records = guardedRecordsCache ?? guardedRecords()
        let changes = records.states.compactMap { state -> GuardedChange? in
            guard state.folder == project, let pending = state.pending else { return nil }
            return GuardedChange(path: state.path, digest: pending.digest, changedBy: pending.changedBy,
                                 changedByIDs: pending.changedByIDs, byGit: pending.byGit, since: pending.since)
        }
        return changes.isEmpty ? nil : changes.sorted { $0.path < $1.path }
    }

    // MARK: The person's

    public func readGuardedChange(_ request: DaemonAPI.GuardedChangeRequest) throws -> GuardedChangeReading {
        let (project, file) = try guardedTarget(request)
        let disk = guardedDiskRead(file, in: project)
        let approved = guardedRecords().state(project, file)?.approvedContent
        return GuardedChangeReading(path: file.path, digest: disk.digest,
                                    approved: approved.map { String(decoding: $0, as: UTF8.self) },
                                    current: disk.data.map { String(decoding: $0, as: UTF8.self) })
    }

    /// Keep: the file as the person was shown it is approved, and used from now on.
    public func keepGuardedChange(_ request: DaemonAPI.GuardedChangeRequest) throws -> DaemonAPI.ProjectSummary {
        let (project, file) = try guardedTarget(request)
        let disk = try guardedShown(request, file, in: project, verb: "kept")
        var records = guardedRecords()
        records.update(project, file) {
            $0.approvedDigest = disk.digest
            $0.approvedContent = disk.data
            $0.pending = nil
        }
        saveGuardedRecords(records, replacing: true)
        guardedFilesMoved(project)
        return try guardedSummary(project)
    }

    /// Undo: the approved copy is written back, or the file taken away when there was none.
    public func undoGuardedChange(_ request: DaemonAPI.GuardedChangeRequest) throws -> DaemonAPI.ProjectSummary {
        let (project, file) = try guardedTarget(request)
        _ = try guardedShown(request, file, in: project, verb: "undone")
        var records = guardedRecords()
        let state = records.state(project, file)
        let url = file.url(in: project)
        do {
            if let content = state?.approvedContent {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try StoreFile.write(content, to: url)
            } else if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
                try FileManager.default.removeItem(at: url)
            }
        } catch {
            throw JSONRPCError(code: JSONRPCError.internalError,
                               message: "\(file.path) could not be put back: \(error.localizedDescription)")
        }
        let disk = guardedDiskRead(file, in: project)
        records.update(project, file) {
            $0.approvedDigest = disk.digest
            $0.approvedContent = disk.data
            $0.pending = nil
        }
        saveGuardedRecords(records, replacing: true)
        guardedFilesMoved(project)
        return try guardedSummary(project)
    }

    private func guardedTarget(_ request: DaemonAPI.GuardedChangeRequest) throws -> (URL, GuardedFile) {
        let project = Project.standardize(request.folder)
        guard projectSummary(for: project) != nil else {
            throw JSONRPCError(code: DaemonAPI.Failure.noSuchProject, message: "\(project.path) is not a project.")
        }
        guard let file = GuardedFile(rawValue: request.path) else {
            throw JSONRPCError(code: JSONRPCError.invalidParams, message: "\(request.path) is not a file the app keeps.")
        }
        return (project, file)
    }

    /// The file is still the one the person was shown.
    private func guardedShown(_ request: DaemonAPI.GuardedChangeRequest, _ file: GuardedFile, in project: URL,
                              verb: String) throws -> (digest: String?, data: Data?) {
        let disk = guardedDiskRead(file, in: project)
        guard disk.digest == request.digest else {
            throw JSONRPCError(code: DaemonAPI.Failure.notChanged,
                               message: "\(file.path) changed again after you looked at it, so it was not \(verb). Look again.")
        }
        return disk
    }

    private func guardedSummary(_ project: URL) throws -> DaemonAPI.ProjectSummary {
        guard let summary = projectSummary(for: project) else {
            throw JSONRPCError(code: DaemonAPI.Failure.noSuchProject, message: "\(project.path) is not a project.")
        }
        return summary
    }
}
