import Foundation
import AgentsKitCore

/// Babysit my pull requests: the starter workflow (038 US4, FR-026, R10).
extension DaemonCore {
    static let babysitterWorkflowID = "babysit-pull-requests"

    /// The starter, as written to the project. `acceptEdits` on purpose, and saying so
    /// in the front matter rather than the body, which is the prompt (Alex, 2026-09-24):
    /// the prompt carries reviewers' words, so the agent may edit files without asking
    /// and asks before anything else.
    static let babysitterFile = """
        ---
        name: Babysit my pull requests
        on:
          - pull-request-checks-failed
          - pull-request-review-comments
          - pull-request-conflicts
        agent: new
        # acceptEdits on purpose: the prompt carries reviewers' words, so the agent edits
        # files without asking and asks before running builds, tests or git. To make it
        # hands-off, allow those commands in this project's Claude settings, or change
        # permission-mode, knowing what that lets a reviewer's comment do.
        permission-mode: acceptEdits
        ---
        Read what changed. Fix what you can, run the build and tests you can, commit, \
        push, and reply to each comment with what you did or why not. If you cannot \
        fix it, say so in one reply and stop.

        """

    /// Write the starter, unless the project already has a workflow with a pull-request
    /// trigger (US4-2), or is at a ceiling (US4-3). The ceilings are the ones every
    /// other new workflow meets, in the words the project page uses for them.
    public func addBabysitter(in folder: URL) throws -> WorkflowSummary {
        let project = Project.standardize(folder)
        adoptWorkflows(in: project)
        if let existing = (workflows[project] ?? [:]).values
            .filter({ $0.triggers.contains(where: \.isPullRequest) })
            .map(\.workflowID).sorted().first {
            throw JSONRPCError(code: DaemonAPI.Failure.babysitterExists,
                               message: "This project already has a babysitter: \(existing).",
                               data: ["workflowID": .string(existing)])
        }
        let records = workflowStore.load()
        for limit in [WorkflowLimit.project, .total] {
            let count = limit == .project ? liveWorkflowCount(in: project, records: records)
                                          : liveWorkflowCount(records: records)
            if count >= limit.allowed {
                throw JSONRPCError(code: DaemonAPI.Failure.workflowLimitReached,
                                   message: "\(limit.sentence). \(limit.remedy).")
            }
        }
        var id = Self.babysitterWorkflowID
        var n = 2
        while FileManager.default.fileExists(atPath: WorkflowFile.url(for: id, in: project).path) {
            id = "\(Self.babysitterWorkflowID)-\(n)"
            n += 1
        }
        do {
            try FileManager.default.createDirectory(at: WorkflowFile.folder(in: project),
                                                    withIntermediateDirectories: true)
            try Data(Self.babysitterFile.utf8).write(to: WorkflowFile.url(for: id, in: project), options: .atomic)
        } catch {
            throw JSONRPCError(code: DaemonAPI.Failure.workflowUnreadable,
                               message: "The babysitter could not be written: \(error.localizedDescription)")
        }
        rescanWorkflows(in: project)
        guard let written = workflow(id, in: project) else {
            throw JSONRPCError(code: DaemonAPI.Failure.noSuchWorkflow, message: "The babysitter went as it was written.")
        }
        if let list = pullRequestLists[project] {
            let updated = withBabysitter(list)
            pullRequestLists[project] = updated
            tellMac(updated)
        }
        return summary(for: written)
    }
}
