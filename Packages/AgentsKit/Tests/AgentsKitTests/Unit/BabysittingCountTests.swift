import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// Three runs in a row and it stops; somebody else acting starts the count again
/// (038 R8, FR-023, FR-024).
@Suite("Babysitting stops when it should")
struct BabysittingCountTests {
    private func pull(head: String, comments: [ReviewItem] = []) -> PullRequest {
        PullRequest(number: 398, title: "Retry flaky upload", url: URL(string: "https://github.com/a/b/pull/398")!,
                    createdAt: Date(timeIntervalSince1970: 0), headBranch: "retry-upload", headOid: head,
                    baseBranch: "main", baseOid: "b", countableComments: comments)
    }

    private func ranThreeTimes() -> PullRequestRecord {
        var record = PullRequestRecord(folder: URL(filePath: "/tmp/p"), number: 398)
        record.notice(pull(head: "a1"))
        for (i, head) in ["b2", "c3", "d4"].enumerated() {
            record.consecutiveRuns += 1
            record.lastRunStartedAt = Date(timeIntervalSince1970: TimeInterval(100 * (i + 1)))
            record.notePushed(head)
            record.notice(pull(head: head))
        }
        return record
    }

    @Test func threeRunsInARowStopIt() {
        let record = ranThreeTimes()
        #expect(record.consecutiveRuns == 3)
        #expect(record.isStopped)
        #expect(WorkflowRefusal.babysittingStopped(pr: 398, runs: 3).needsAPerson)
    }

    @Test func babysittingsOwnPushDoesNotStartTheCountAgain() {
        var record = ranThreeTimes()
        record.notice(pull(head: "d4"))
        #expect(record.isStopped)
    }

    @Test func aPushByAnybodyElseStartsItAgain() {
        var record = ranThreeTimes()
        record.notice(pull(head: "e5-by-hand"))
        #expect(!record.isStopped)
        #expect(record.consecutiveRuns == 0)
    }

    @Test func aNewerReviewCommentStartsItAgain() {
        var record = ranThreeTimes()
        let comment = ReviewItem(id: 9, kind: .threadComment, author: "jdoe", body: "Try the other way",
                                 createdAt: Date(timeIntervalSince1970: 500))
        record.notice(pull(head: "d4", comments: [comment]))
        #expect(!record.isStopped)
    }

    @Test func anOlderCommentOrBabysittingsOwnReplyDoesNot() {
        var record = ranThreeTimes()
        record.notePosted(10)
        let older = ReviewItem(id: 8, kind: .threadComment, author: "jdoe", body: "old",
                               createdAt: Date(timeIntervalSince1970: 50))
        let ours = ReviewItem(id: 10, kind: .threadComment, author: "jdoe", body: "ours",
                              createdAt: Date(timeIntervalSince1970: 900))
        record.notice(pull(head: "d4", comments: [older, ours]))
        #expect(record.isStopped)
    }

    @Test func resumeStartsItAgain() {
        var record = ranThreeTimes()
        record.stoppedAt = Date()
        record.resume()
        #expect(!record.isStopped)
        #expect(record.consecutiveRuns == 0)
    }
}
