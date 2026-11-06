import AgentsKitCore
import Foundation
import Testing

/// What the Review page reads from a guarded change and an approval (#1472).
struct ReviewModelTests {
    private func change(_ path: String) -> GuardedChange {
        GuardedChange(path: path, digest: "d", changedBy: [], changedByIDs: [], byGit: true, since: .now)
    }

    @Test func aGuardedChangeOpensItsApproval() {
        #expect(change(".agents/pins.json").approvalID == "file:.agents/pins.json")
        #expect(change(".agents/workflows/nightly.md").approvalID == "workflow:nightly")
        let approval = Approval(kind: .workflow, key: "nightly", title: "Nightly", digest: "d", line: "", actions: [.approve])
        #expect(approval.id == change(".agents/workflows/nightly.md").approvalID)
    }

    @Test func aReadingCountsItsLines() {
        let reading = GuardedChangeReading(path: "a", digest: "d", approved: "one\ntwo\nthree\n", current: "one\n2\nthree\nfour\n")
        #expect(reading.counts.added == 2)
        #expect(reading.counts.removed == 1)
        #expect(!reading.isCut)
    }

    @Test func aLongReadingIsCut() {
        let long = (1...500).map(String.init).joined(separator: "\n")
        #expect(GuardedChangeReading(path: "a", digest: "d", approved: nil, current: long).isCut)
    }

    @Test func onlyKindsWithLinesHaveAReview() {
        let reviewed = Approval.Kind.allCases.filter {
            Approval(kind: $0, key: "k", title: "", digest: nil, line: "", actions: []).hasReview
        }
        #expect(reviewed == [.mcpServer, .workflow, .plugin, .file, .deploy])
    }

    /// A waiting deploy (#3587) is approved or rejected, and its kind says so.
    @Test func aDeployIsApprovedOrRejected() {
        let deploy = Approval(kind: .deploy, key: "o/r/77", title: "Release to production", digest: "1:11",
                              line: "v0.17.0 waits for your approval", actions: [.approve, .deny])
        #expect(deploy.kindWord == "Deploy")
        #expect(deploy.word(for: .approve) == "Approve")
        #expect(deploy.word(for: .deny) == "Reject")
        #expect(!deploy.opensItsSubject)
        #expect(!deploy.isSession)
    }
}
