import Foundation
import Testing
@testable import AgentsKitCore

/// A pull request's page in the Work look (#4406, `specs/4328-work-look/pull-request.md`): the
/// merge box's rows, border and buttons in each state.
@Suite("Work look: the pull request page")
struct WorkPullLookTests {
    typealias Check = DaemonAPI.ForgeCheck
    let now = Date(timeIntervalSince1970: 1_793_000_000)

    func pull(state: String = "open", draft: Bool = false, checks: String? = "passing", review: String? = "approved",
              mergeable: String? = "mergeable", autoMerge: Bool = false, list: [Check]? = nil, threads: Int? = nil,
              head: String? = "abc123") -> DaemonAPI.ForgeItemDetail {
        let item = DaemonAPI.ForgeItem(node: .init(kind: "pr", ref: "github:example/shop#21"), title: "Pay part with a gift card",
                                       state: state, updatedAt: now, draft: draft, checks: checks, review: review,
                                       mergeable: mergeable, autoMerge: autoMerge)
        return DaemonAPI.ForgeItemDetail(item: item, checks: list, reviewThreads: threads, filesChanged: 6, head: head,
                                         mergeMethods: [.squash, .merge])
    }

    @Test func readyToMerge() throws {
        let box = try #require(WorkLook.mergeBox(pull(list: [Check(name: "build", state: "passing"), Check(name: "lint", state: "skipped")])))
        #expect(box.border == .pass)
        #expect(box.rows.map(\.title) == ["Approved", "All checks passed", "No conflicts with the base branch"])
        #expect(box.rows.map(\.line) == [nil, "1 passed, 1 skipped", nil])
        #expect(box.merges && !box.waits && box.approves && !box.reruns && !box.checksOpen)
        #expect(WorkLook.mergeMain([.squash, .merge], waits: box.waits) == "Squash and merge")
    }

    @Test func aFailedCheckOpensTheListAndWaits() throws {
        let list = [Check(name: "build", state: "passing"), Check(name: "test", state: "failing"), Check(name: "e2e", state: "running")]
        let box = try #require(WorkLook.mergeBox(pull(checks: "failing", list: list)))
        #expect(box.border == .fail)
        #expect(box.rows.first { $0.kind == .checks } == .init(kind: .checks, sign: .fail, title: "1 check failed", line: "1 failed, 1 passed, 1 running"))
        #expect(box.checksOpen && box.reruns && box.waits && box.merges)
        #expect(WorkLook.mergeMain([.squash], waits: box.waits) == "Merge when checks pass")
        #expect(WorkLook.checksInOrder(list).map(\.name) == ["test", "e2e", "build"])
    }

    @Test func runningChecksWait() throws {
        let box = try #require(WorkLook.mergeBox(pull(checks: "running", review: "review_required", threads: 2)))
        #expect(box.border == .info)
        #expect(box.rows.first { $0.kind == .review } == .init(kind: .review, sign: .wait, title: "Review required", line: "No one approved yet · 2 unresolved threads"))
        #expect(box.rows.first { $0.kind == .checks } == .init(kind: .checks, sign: .wait, title: "Checks are running", line: nil))
        #expect(box.waits && !box.reruns)
    }

    @Test func aDraftCannotMerge() throws {
        let box = try #require(WorkLook.mergeBox(pull(draft: true, review: "review_required")))
        #expect(box.rows.first?.kind == .draft)
        #expect(!box.rows.contains { $0.kind == .review })
        #expect(!box.merges && !box.approves)
        #expect(box.border == .info)
    }

    @Test func conflictsStopTheMerge() throws {
        let box = try #require(WorkLook.mergeBox(pull(mergeable: "conflicting")))
        #expect(box.border == .fail)
        #expect(box.rows.last?.title == "This branch has conflicts")
        #expect(!box.merges && box.resolve && box.approves)
        #expect(WorkLook.mergeBox(pull(mergeable: "unknown"))?.rows.contains { $0.kind == .conflicts } == false)
    }

    @Test func autoMergeOnHasNoMergeButton() throws {
        let box = try #require(WorkLook.mergeBox(pull(checks: "running", autoMerge: true)))
        #expect(box.rows.last == .init(kind: .autoMerge, sign: .info, title: "Auto-merge is on", line: "Squash and merge when the checks pass"))
        #expect(!box.merges && box.approves)
    }

    @Test func noBoxOnAMergedOrClosedPullRequestOrAnIssue() {
        #expect(WorkLook.mergeBox(pull(state: "merged")) == nil)
        #expect(WorkLook.mergeBox(pull(state: "closed")) == nil)
        var issue = pull()
        issue.item.node = .init(kind: "issue", ref: "github:example/shop#12")
        #expect(WorkLook.mergeBox(issue) == nil)
    }

    @Test func checksWithNoListSayTheSummary() {
        #expect(WorkLook.checksRow(nil, summary: "failing")?.title == "Some checks failed")
        #expect(WorkLook.checksRow([], summary: "none") == nil)
        #expect(WorkLook.checksRow(nil, summary: nil) == nil)
        #expect(WorkLook.checksRow([Check(name: "a", state: "failing"), Check(name: "b", state: "failing")], summary: nil)?.title == "2 checks failed")
    }

    @Test func reviewRows() {
        #expect(WorkLook.reviewRow("changes_requested", threads: 1)?.line == "A reviewer asked for changes · 1 unresolved thread")
        #expect(WorkLook.reviewRow(nil, threads: 3) == nil)
        #expect(WorkLook.reviewersWords(nil) == "No one")
        #expect(WorkLook.reviewersWords("approved") == "Approved")
    }

    @Test func headerAndPanelWords() {
        #expect(WorkLook.filesChanged(6) == "Files changed 6")
        #expect(WorkLook.filesChanged(nil) == "Files changed")
        #expect(WorkLook.branchWords(1) == "1 file")
        #expect(WorkLook.branchWords(6) == "6 files")
        let updated = now.addingTimeInterval(-2 * 3600)
        #expect(WorkLook.pullStateWords(author: "sam", state: "open", updated: updated, comments: 4, narrow: false, now: now)
            == "sam opened this pull request · updated 2 h ago · 4 comments")
        #expect(WorkLook.pullStateWords(author: "sam", state: "open", updated: updated, comments: 4, narrow: true, now: now)
            == "sam · 2 h · 4 comments")
        #expect(WorkLook.pullStateWords(author: "sam", state: "merged", updated: updated, comments: 0, narrow: false, now: now)
            == "sam’s pull request was merged · updated 2 h ago")
    }
}
