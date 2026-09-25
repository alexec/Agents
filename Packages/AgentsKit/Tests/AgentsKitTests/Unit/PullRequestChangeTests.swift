import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// What counts as a change to fire on, and firing on each one once (038 R6, FR-013).
@Suite("Pull request changes")
struct PullRequestChangeTests {
    private let folder = URL(filePath: "/tmp/a-project")
    private let workflowID = "babysit-pull-requests"

    private func pull(checks: PullRequestChecks = .passing, conflicts: PullRequestConflicts = .clean,
                      comments: [ReviewItem] = [], viewerLastActionAt: Date? = nil,
                      headOid: String = "aaa", baseOid: String = "bbb") -> PullRequest {
        PullRequest(number: 412, title: "Fix login redirect", url: URL(string: "https://github.com/a/b/pull/412")!,
                    createdAt: Date(timeIntervalSince1970: 0), headBranch: "fix", headOid: headOid,
                    baseBranch: "main", baseOid: baseOid, checks: checks, conflicts: conflicts,
                    countableComments: comments, viewerLastActionAt: viewerLastActionAt)
    }

    private func comment(_ id: Int, at seconds: TimeInterval) -> ReviewItem {
        ReviewItem(id: id, kind: .threadComment, author: "jdoe", body: "Please fix \(id)",
                   createdAt: Date(timeIntervalSince1970: seconds))
    }

    private func fired(_ changes: [PullRequestChanges.Change]) -> PullRequestRecord {
        var record = PullRequestRecord(folder: folder, number: 412)
        for change in changes {
            record.firedKeys[PullRequestChanges.slot(workflowID: workflowID, trigger: change.trigger)] = change.key
        }
        return record
    }

    private let build = FailedCheck(id: "9001", name: "build", logURL: nil)
    private let lint = FailedCheck(id: "9002", name: "lint", logURL: nil)

    @Test func theSameFailingCheckFiresOnce() {
        let failing = pull(checks: .failing([build]))
        let first = PullRequestChanges.unfired([.pullRequestChecksFailed], on: failing, record: nil, workflowID: workflowID)
        #expect(first.map(\.key) == ["checks:aaa:9001"])
        #expect(first.first?.checks == [build])
        #expect(PullRequestChanges.unfired([.pullRequestChecksFailed], on: failing, record: fired(first),
                                           workflowID: workflowID).isEmpty)
    }

    @Test func aNewFailingCheckOrANewCommitFiresAgain() {
        let record = fired(PullRequestChanges.unfired([.pullRequestChecksFailed], on: pull(checks: .failing([build])),
                                                      record: nil, workflowID: workflowID))
        #expect(PullRequestChanges.unfired([.pullRequestChecksFailed], on: pull(checks: .failing([build, lint])),
                                           record: record, workflowID: workflowID).map(\.key) == ["checks:aaa:9001,9002"])
        #expect(!PullRequestChanges.unfired([.pullRequestChecksFailed], on: pull(checks: .failing([build]), headOid: "ccc"),
                                            record: record, workflowID: workflowID).isEmpty)
    }

    @Test func passingOrRunningChecksAreNothingToFireOn() {
        for checks in [PullRequestChecks.passing, .running, .none] {
            #expect(PullRequestChanges.unfired([.pullRequestChecksFailed], on: pull(checks: checks),
                                               record: nil, workflowID: workflowID).isEmpty)
        }
    }

    @Test func aConflictFiresOncePerBaseAndUnknownNever() {
        let conflicting = pull(conflicts: .conflicting)
        let first = PullRequestChanges.unfired([.pullRequestConflicts], on: conflicting, record: nil, workflowID: workflowID)
        #expect(first.map(\.key) == ["conflict:bbb"])
        #expect(first.first?.conflictsWith == "main")
        #expect(PullRequestChanges.unfired([.pullRequestConflicts], on: conflicting, record: fired(first),
                                           workflowID: workflowID).isEmpty)
        #expect(!PullRequestChanges.unfired([.pullRequestConflicts], on: pull(conflicts: .conflicting, baseOid: "ddd"),
                                            record: fired(first), workflowID: workflowID).isEmpty)
        #expect(PullRequestChanges.unfired([.pullRequestConflicts], on: pull(conflicts: .unknown),
                                           record: nil, workflowID: workflowID).isEmpty)
    }

    /// First sight: only what is newer than the viewer's own latest word or push, so a
    /// long-settled review does not come back up (R6).
    @Test func onFirstSightOnlyCommentsAfterTheViewersLastActionCount() {
        let comments = [comment(1, at: 100), comment(2, at: 300)]
        let changes = PullRequestChanges.unfired([.pullRequestReviewComments],
                                                 on: pull(comments: comments, viewerLastActionAt: Date(timeIntervalSince1970: 200)),
                                                 record: nil, workflowID: workflowID)
        #expect(changes.first?.comments.map(\.id) == [2])
        #expect(changes.first?.key == "comments:2")
    }

    @Test func afterAFireOnlyNewerCommentsCount() {
        var record = PullRequestRecord(folder: folder, number: 412)
        record.commentWatermark[workflowID] = 2
        let changes = PullRequestChanges.unfired([.pullRequestReviewComments],
                                                 on: pull(comments: [comment(1, at: 1), comment(2, at: 2), comment(3, at: 3)]),
                                                 record: record, workflowID: workflowID)
        #expect(changes.first?.comments.map(\.id) == [3])
        record.commentWatermark[workflowID] = 3
        #expect(PullRequestChanges.unfired([.pullRequestReviewComments],
                                           on: pull(comments: [comment(3, at: 3)]),
                                           record: record, workflowID: workflowID).isEmpty)
    }

    @Test func babysittingsOwnRepliesNeverCount() {
        var record = PullRequestRecord(folder: folder, number: 412)
        record.notePosted(7)
        #expect(PullRequestChanges.unfired([.pullRequestReviewComments], on: pull(comments: [comment(7, at: 5)]),
                                           record: record, workflowID: workflowID).isEmpty)
    }

    @Test func eachWorkflowHasItsOwnKeys() {
        let failing = pull(checks: .failing([build]))
        let record = fired(PullRequestChanges.unfired([.pullRequestChecksFailed], on: failing, record: nil,
                                                      workflowID: workflowID))
        #expect(!PullRequestChanges.unfired([.pullRequestChecksFailed], on: failing, record: record,
                                            workflowID: "another").isEmpty)
    }

    @Test func allOfAWorkflowsTriggersAreLookedAtTogether() {
        let changes = PullRequestChanges.unfired(WorkflowTrigger.pullRequestTriggers + [.agentFinished],
                                                 on: pull(checks: .failing([build]), conflicts: .conflicting,
                                                          comments: [comment(1, at: 1)]),
                                                 record: nil, workflowID: workflowID)
        #expect(changes.map(\.trigger) == WorkflowTrigger.pullRequestTriggers)
    }
}
