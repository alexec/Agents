import AgentsKitCore
import Foundation

/// A workflow waiting for an OK, asked as the question a changed guarded file is (#569):
/// who changed it, the lines against the approved copy, and Keep or Undo, on every client,
/// through `GuardedChangeCard` and `NeedID.guardedChange`, by the file's path.
///
/// Keep is Approve. Undo writes back the copy kept beside `approvedDigest` in
/// `workflows.json`, or removes a file never approved. Approve and Deny on the
/// workflow's own page go on as before.
///
/// Who changed it is named as for the guarded files: the agents whose turns were running
/// when the change was first seen, by the project's watch or at the end of a turn; or,
/// with none, a merge or pull when the file is what the last commit holds.
extension DaemonCore {
    /// The waiting workflows of a project this host has read, as questions.
    func waitingWorkflowChanges(in project: URL, records: WorkflowRecords? = nil) -> [GuardedChange] {
        guard let held = workflows[project] else { return [] }
        let records = records ?? workflowStore.load()
        return held.values.compactMap { workflow -> GuardedChange? in
            guard workflow.runs(on: MachineID.current), !workflow.isArchived else { return nil }
            let state = records.state(folder: project, workflowID: workflow.workflowID)
            guard let waiting = awaitingApproval(workflow, state: state, records: records) else { return nil }
            let pending = state?.waitingChange.flatMap { $0.digest == waiting.digest ? $0 : nil }
                ?? .init(digest: waiting.digest, since: .distantPast)
            return guardedChange(project, GuardedChange.workflowPath(workflow.workflowID), pending)
        }
        .sorted { $0.path < $1.path }
    }

    /// Name who changed each workflow now waiting and not yet named, keep a copy of each
    /// approved file that has none yet (one approved before copies were kept), and tell
    /// every client when the questions moved. `witness` is an agent whose turn just ended.
    func markWorkflowChanges(in folder: URL, witness: Agent? = nil) {
        let project = Project.standardize(folder)
        guard let held = workflows[project] else { return }
        var records = workflowStore.load()
        var changed = false
        var running: [Agent]?
        var unnamed: [(workflow: Workflow, digest: String)] = []
        for workflow in held.values where workflow.runs(on: MachineID.current) {
            let id = workflow.workflowID
            let state = records.state(folder: project, workflowID: id)
            if let approved = state?.approvedDigest, state?.approvedContent == nil,
               workflowDigest(workflow) == approved, let copy = approvedCopy(of: workflow, digest: approved) {
                records.update(folder: project, workflowID: id) { $0.approvedContent = copy }
                changed = true
            }
            guard !workflow.isArchived, let waiting = awaitingApproval(workflow, state: state, records: records) else {
                if state?.waitingChange != nil {
                    records.update(folder: project, workflowID: id) { $0.waitingChange = nil }
                    changed = true
                }
                continue
            }
            // Already named, as it is: whoever's turn ends now did not make it.
            if state?.waitingChange?.digest == waiting.digest { continue }
            if running == nil { running = agentsWithTurns(in: project) }
            var witnesses = running ?? []
            if let witness, !witnesses.contains(where: { $0.id == witness.id }) { witnesses.append(witness) }
            var pending = GuardedFileState.Pending(digest: waiting.digest, since: now())
            pending.changedByIDs = witnesses.map(\.id)
            pending.changedBy = witnesses.map { $0.title ?? "Untitled" }
            records.update(folder: project, workflowID: id) { $0.waitingChange = pending }
            changed = true
            if witnesses.isEmpty { unnamed.append((workflow, waiting.digest)) }
        }
        if changed { keepQuietly("workflow history") { try workflowStore.save(records) } }
        workflowQuestionsMoved(project)
        guard !unnamed.isEmpty, Self.isInRepository(project) else { return }
        Task { await self.nameGitWorkflowChanges(unnamed, in: project) }
    }

    /// A change no turn was running for is a merge's or pull's when the file is what the
    /// last commit holds.
    private func nameGitWorkflowChanges(_ unnamed: [(workflow: Workflow, digest: String)], in project: URL) async {
        var byGit: [String] = []
        for (workflow, digest) in unnamed {
            let url = WorkflowFile.url(for: workflow.workflowID, in: project)
            guard let data = try? Data(contentsOf: url), ContentDigest.sha256(data) == digest else { continue }
            let path = GuardedChange.workflowPath(workflow.workflowID)
            if await Self.isCommitted(data, path: path, in: project) { byGit.append(workflow.workflowID) }
        }
        guard !byGit.isEmpty else { return }
        var records = workflowStore.load()
        var changed = false
        for id in byGit {
            // Only the change looked at: a later one is named afresh.
            guard let pending = records.state(folder: project, workflowID: id)?.waitingChange,
                  pending.changedBy.isEmpty, !pending.byGit,
                  unnamed.contains(where: { $0.workflow.workflowID == id && $0.digest == pending.digest }) else { continue }
            records.update(folder: project, workflowID: id) { $0.waitingChange?.byGit = true }
            changed = true
        }
        guard changed else { return }
        keepQuietly("workflow history") { try workflowStore.save(records) }
        workflowQuestionsMoved(project)
    }

    /// The project's summary and every client's question, when what waits has moved.
    func workflowQuestionsMoved(_ project: URL) {
        let now = waitingWorkflowChanges(in: project)
        guard (workflowQuestions[project] ?? []) != now else { return }
        workflowQuestions[project] = now.isEmpty ? nil : now
        if let summary = projectSummary(for: project) { sendProject(summary) }
        reconsider()
    }

    // MARK: The person's

    func readWorkflowChange(_ request: DaemonAPI.GuardedChangeRequest, workflowID: String) throws -> GuardedChangeReading {
        let (project, workflow) = try workflowTarget(request, workflowID)
        let url = WorkflowFile.url(for: workflowID, in: project)
        let approved = workflowStore.load().state(folder: project, workflowID: workflowID)?.approvedContent
        return GuardedChangeReading(path: request.path, digest: workflowDigest(workflow),
                                    approved: approved.map { String(decoding: $0, as: UTF8.self) },
                                    current: (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) })
    }

    /// Keep: Approve, of the file as the person was shown it.
    func keepWorkflowChange(_ request: DaemonAPI.GuardedChangeRequest, workflowID: String) throws -> DaemonAPI.ProjectSummary {
        let (project, _) = try workflowTarget(request, workflowID)
        guard let digest = request.digest else { throw workflowChangedAgain(request.path, verb: "kept") }
        _ = try approveWorkflow(.init(folder: project, workflowID: workflowID, digest: digest))
        return try workflowProjectSummary(project)
    }

    /// Undo: the approved copy written back, or the file removed when none was ever approved.
    func undoWorkflowChange(_ request: DaemonAPI.GuardedChangeRequest, workflowID: String) throws -> DaemonAPI.ProjectSummary {
        let (project, workflow) = try workflowTarget(request, workflowID)
        guard request.digest != nil, workflowDigest(workflow) == request.digest else {
            throw workflowChangedAgain(request.path, verb: "undone")
        }
        var records = workflowStore.load()
        // A record that could not be read approves nothing, so it has nothing to put back:
        // Undo would remove every workflow in the project.
        guard !records.unreadable else {
            throw JSONRPCError(code: DaemonAPI.Failure.notChanged,
                               message: "The record of approved workflows could not be read, so there is no approved copy of \(request.path) to put back. Keep it, or deny it on its page.")
        }
        let state = records.state(folder: project, workflowID: workflowID)
        let url = WorkflowFile.url(for: workflowID, in: project)
        do {
            if let approved = state?.approvedDigest {
                guard let content = state?.approvedContent, ContentDigest.sha256(content) == approved else {
                    throw JSONRPCError(code: DaemonAPI.Failure.notChanged,
                                       message: "No copy of \(request.path) was kept when it was approved, so it cannot be put back. Keep it, or deny it on its page.")
                }
                try content.write(to: url, options: .atomic)
            } else {
                try FileManager.default.removeItem(at: url)
            }
        } catch let error as JSONRPCError {
            throw error
        } catch {
            if let failure = WriteFailure(error, keeping: url.lastPathComponent) { throw Self.refusal(failure) }
            throw JSONRPCError(code: JSONRPCError.internalError,
                               message: "\(request.path) could not be put back: \(error.localizedDescription)")
        }
        records.update(folder: project, workflowID: workflowID) {
            $0.waitingChange = nil
            if case .refused(.awaitingApproval, _, _) = $0.lastOutcome { $0.lastOutcome = nil }
        }
        try keep("this workflow's settings") { try workflowStore.save(records, replacing: true) }
        // At once rather than by the watch, so the page and the question move with the answer.
        rescanWorkflows(in: project)
        announceWorkflow(workflow, records: records)
        markWorkflowChanges(in: project)
        return try workflowProjectSummary(project)
    }

    private func workflowTarget(_ request: DaemonAPI.GuardedChangeRequest,
                                _ workflowID: String) throws -> (URL, Workflow) {
        let project = Project.standardize(request.folder)
        guard projectSummary(for: project) != nil else {
            throw JSONRPCError(code: DaemonAPI.Failure.noSuchProject, message: "\(project.path) is not a project.")
        }
        guard let workflow = workflow(workflowID, in: project) else {
            throw JSONRPCError(code: DaemonAPI.Failure.noSuchWorkflow,
                               message: "There is no workflow called \(workflowID) in this project.")
        }
        return (project, workflow)
    }

    private func workflowChangedAgain(_ path: String, verb: String) -> JSONRPCError {
        JSONRPCError(code: DaemonAPI.Failure.notChanged,
                     message: "\(path) changed again after you looked at it, so it was not \(verb). Look again.")
    }

    private func workflowProjectSummary(_ project: URL) throws -> DaemonAPI.ProjectSummary {
        guard let summary = projectSummary(for: project) else {
            throw JSONRPCError(code: DaemonAPI.Failure.noSuchProject, message: "\(project.path) is not a project.")
        }
        return summary
    }
}
