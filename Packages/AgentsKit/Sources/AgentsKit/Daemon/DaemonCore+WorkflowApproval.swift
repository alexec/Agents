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
    func workflowDigest(_ workflow: Workflow) -> String? {
        let url = WorkflowFile.url(for: workflow.workflowID, in: workflow.folder)
        return (try? Data(contentsOf: url)).map(ContentDigest.sha256)
    }

    /// What a workflow is waiting on, or nil when the file is the one approved.
    ///
    /// Nothing waits before approval has begun: everything present then is about to be
    /// approved as it stands, and the daemon begins approval before anything can fire.
    func awaitingApproval(_ workflow: Workflow, state: WorkflowState?,
                          records: WorkflowRecords) -> WorkflowApproval? {
        guard records.approvalsBegan != nil, let digest = workflowDigest(workflow), digest != state?.approvedDigest else { return nil }
        return WorkflowApproval(digest: digest, isNew: state?.approvedDigest == nil)
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
        workflowStore.save(records)
    }

    /// Record `digest` as approved for the workflow, in the records given.
    func approve(_ workflow: Workflow, digest: String, in records: inout WorkflowRecords) {
        records.update(folder: workflow.folder, workflowID: workflow.workflowID) {
            $0.approvedDigest = digest
            // A refusal for waiting belonged to the file before this one.
            if case .refused(.awaitingApproval, _, _) = $0.lastOutcome { $0.lastOutcome = nil }
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
        approve(workflow, digest: request.digest, in: &records)
        workflowStore.save(records)
        let summary = summary(for: workflow, records: records)
        broadcast(DaemonAPI.Notification.workflowChanged, summary)
        return summary
    }
}
