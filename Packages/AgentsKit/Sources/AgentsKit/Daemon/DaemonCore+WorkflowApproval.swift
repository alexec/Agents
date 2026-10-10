import Foundation

/// Nothing runs from a workflow file the person has not looked at (security review).
///
/// A file in `.agents/workflows/` can arrive by any road — an agent's own edit tool,
/// which in some modes asks nobody, a `git pull`, a pull request's branch, an editor —
/// and whatever `permission-mode` it names is what it runs with. So an agent allowed
/// only to edit files could give itself a standing agent allowed everything. What the
/// person approves is the file's content: a digest of it is kept here, outside the
/// project, and a file that no longer matches waits until they approve it again.
///
/// Three roads approve without a click, each one the person's own: every file present
/// when approval began, a save through the app's own workflow page, and Approve itself.
extension DaemonCore {
    /// SHA-256 of the workflow's file as it is now, or nil when it cannot be read — a
    /// file that cannot be read is already refused as unreadable.
    ///
    /// Kept by the file's stamp (#218): every listing, summary and fire asks this of
    /// every workflow, and a `stat` is all an unchanged file costs. The stamp holds the
    /// change time, which no one can set back, so a file rewritten and given its old
    /// modification date is still read and hashed afresh.
    func workflowDigest(_ workflow: Workflow) -> String? {
        let url = WorkflowFile.url(for: workflow.workflowID, in: workflow.folder)
        guard let stamp = DigestStamp(url.path) else {
            workflowDigests[url.path] = nil
            return nil
        }
        if let known = workflowDigests[url.path], known.stamp == stamp { return known.digest }
        guard let data = try? Data(contentsOf: url) else { return nil }
        let digest = ContentDigest.sha256(data)
        workflowDigestReads += 1
        // Kept only when the file did not move under the read.
        if DigestStamp(url.path) == stamp { workflowDigests[url.path] = (stamp, digest) }
        return digest
    }

    /// What a workflow is waiting on, or nil when the file is the one approved, or the
    /// one denied on this host (#391): a denial is an answer, so it no longer waits.
    ///
    /// Nothing waits before approval has begun: everything present then is about to be
    /// approved as it stands, and the daemon begins approval before anything can fire.
    /// A records file that could not be read has begun and approved nothing (#169).
    func awaitingApproval(_ workflow: Workflow, state: WorkflowState?,
                          records: WorkflowRecords) -> WorkflowApproval? {
        guard records.approvalsBegan != nil, let digest = workflowDigest(workflow), digest != state?.approvedDigest,
              digest != state?.deniedDigest else { return nil }
        return WorkflowApproval(digest: digest, isNew: state?.approvedDigest == nil,
                                note: records.unreadable ? ApprovalFile.note(workflowStore.file) : nil)
    }

    /// The file as the person denied it on this host, while it is still the file and has
    /// not been approved since (#391), or nil. A denied workflow runs nothing here, by
    /// trigger or by Run now, and is neither waiting nor among the approved.
    func deniedHere(_ workflow: Workflow, state: WorkflowState?) -> WorkflowApproval? {
        guard let denied = state?.deniedDigest, denied != state?.approvedDigest,
              workflowDigest(workflow) == denied else { return nil }
        return WorkflowApproval(digest: denied, isNew: state?.approvedDigest == nil)
    }

    /// The first start with approval: every file already here is approved as it stands,
    /// so nothing the person was relying on stops. Once only, however many restarts.
    func beginWorkflowApprovalsIfNeeded() {
        var records = workflowStore.load()
        guard records.approvalsBegan == nil else { return }
        for (_, byID) in workflows {
            for workflow in byID.values {
                guard let digest = workflowDigest(workflow) else { continue }
                records.update(folder: workflow.folder, workflowID: workflow.workflowID) {
                    $0.approvedDigest = digest
                }
            }
        }
        records.approvalsBegan = Date()
        keepQuietly("workflow history") { try workflowStore.save(records) }
    }

    /// Record `digest` as approved for the workflow, in the records given.
    func approve(_ workflow: Workflow, digest: String, in records: inout WorkflowRecords) {
        records.update(folder: workflow.folder, workflowID: workflow.workflowID) {
            $0.approvedDigest = digest
            // Approve on this host takes back a denial on it (#391).
            $0.deniedDigest = nil
            // A refusal for waiting, or for being denied, belonged to before this.
            switch $0.lastOutcome {
            case .refused(.awaitingApproval, _, _), .refused(.deniedHere, _, _): $0.lastOutcome = nil
            default: break
            }
        }
    }

    /// The person's Approve. Only the file they were shown: if it has changed since,
    /// nothing is approved and they are told, because approving a file nobody saw is
    /// the whole thing this exists to stop.
    public func approveWorkflow(_ request: DaemonAPI.WorkflowApproveRequest) throws -> WorkflowSummary {
        guard let workflow = workflow(request.workflowID, in: request.folder) else {
            throw JSONRPCError(code: DaemonAPI.Failure.noSuchWorkflow,
                               message: "There is no workflow called \(request.workflowID) in this project.")
        }
        guard workflowDigest(workflow) == request.digest else {
            throw JSONRPCError(code: DaemonAPI.Failure.notChanged,
                               message: "\(workflow.name) changed after you looked at it, so it was not approved. Look again.")
        }
        var records = workflowStore.load()
        // Past the project's waiting ceiling, it waits its turn (#132): listed, inert,
        // and approvable once one of the ones ahead of it is approved or removed.
        if limitReached(by: workflow, records: records) == .project {
            throw JSONRPCError(code: DaemonAPI.Failure.workflowLimitReached,
                               message: "\(WorkflowLimit.project.sentence(total: workflowTotalLimit())). \(WorkflowLimit.project.remedy).")
        }
        approve(workflow, digest: request.digest, in: &records)
        try keep("this workflow's settings") { try workflowStore.save(records, replacing: true) }
        let summary = summary(for: workflow, records: records)
        announceWorkflow(workflow, records: records)
        // Its place among the waiting is free for the next in line, and one turned on
        // now takes a place under the total, which every project shares (#506).
        rebroadcastAllWorkflows(except: (folder: workflow.folder, workflowID: workflow.workflowID))
        return summary
    }

    /// The person's Deny (#391): not on this host. Of the file they were shown, as
    /// Approve is, and kept beside the approval rather than in the file, so other hosts
    /// still see it waiting and the project's history shows nothing. A later change to
    /// the file waits for an OK again.
    public func denyWorkflow(_ request: DaemonAPI.WorkflowApproveRequest) throws -> WorkflowSummary {
        guard let workflow = workflow(request.workflowID, in: request.folder) else {
            throw JSONRPCError(code: DaemonAPI.Failure.noSuchWorkflow,
                               message: "There is no workflow called \(request.workflowID) in this project.")
        }
        guard workflowDigest(workflow) == request.digest else {
            throw JSONRPCError(code: DaemonAPI.Failure.notChanged,
                               message: "\(workflow.name) changed after you looked at it, so it was not denied. Look again.")
        }
        var records = workflowStore.load()
        records.update(folder: workflow.folder, workflowID: workflow.workflowID) {
            $0.deniedDigest = request.digest
            // Denying an approved file takes the approval back on this host.
            if $0.approvedDigest == request.digest { $0.approvedDigest = nil }
            if case .refused(.awaitingApproval, _, _) = $0.lastOutcome { $0.lastOutcome = nil }
        }
        try keep("this workflow's settings") { try workflowStore.save(records, replacing: true) }
        let summary = summary(for: workflow, records: records)
        announceWorkflow(workflow, records: records)
        // Like Approve and Archive, it frees a place among the waiting.
        rebroadcastWorkflows(in: workflow.folder, except: [workflow.workflowID])
        return summary
    }
}

/// Which version of a file is on disk, as one `stat` tells it, for knowing a digest is
/// still the file's (#218): inode, size, and the modification and change times to the
/// nanosecond. The change time moves on every write and cannot be set by hand.
struct DigestStamp: Equatable, Sendable {
    var inode: UInt64
    var size: Int64
    var modified: [Int]
    var changed: [Int]

    init?(_ path: String) {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        #if canImport(Darwin)
        let modified = info.st_mtimespec, changed = info.st_ctimespec
        #else
        let modified = info.st_mtim, changed = info.st_ctim
        #endif
        inode = UInt64(info.st_ino)
        size = Int64(info.st_size)
        self.modified = [Int(modified.tv_sec), Int(modified.tv_nsec)]
        self.changed = [Int(changed.tv_sec), Int(changed.tv_nsec)]
    }
}
