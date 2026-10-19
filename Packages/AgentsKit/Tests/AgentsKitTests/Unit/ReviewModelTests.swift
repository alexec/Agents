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
        #expect(reviewed == [.mcpServer, .workflow, .plugin, .file])
    }
}
