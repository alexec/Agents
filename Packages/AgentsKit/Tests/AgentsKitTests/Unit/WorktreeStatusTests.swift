import Foundation
import Testing
@testable import AgentsKit

/// The words a worktree's row says about its git status, on the Mac and the phone.
@Suite("A worktree's git status in a few words")
struct WorktreeStatusTests {
    @Test func nothingPendingIsClean() {
        #expect(DaemonAPI.WorktreeStatus(uncommitted: 0, ahead: 0, behind: 0, unmerged: 0).summary == "clean")
        #expect(!DaemonAPI.WorktreeStatus(uncommitted: 0).hasPendingWork)
    }

    @Test func uncommittedAlone() {
        let status = DaemonAPI.WorktreeStatus(uncommitted: 3)
        #expect(status.summary == "3 uncommitted")
        #expect(status.hasPendingWork)
    }

    @Test func everythingInOrder() {
        let status = DaemonAPI.WorktreeStatus(uncommitted: 3, ahead: 1, behind: 2, unmerged: 2)
        #expect(status.summary == "3 uncommitted · 2 unmerged · ↑1 ↓2")
    }

    @Test func onlyBehindItsUpstream() {
        let status = DaemonAPI.WorktreeStatus(uncommitted: 0, ahead: 0, behind: 4, unmerged: 0)
        #expect(status.summary == "↓4")
        #expect(!status.hasPendingWork, "behind loses nothing")
    }

    @Test func noUpstreamSaysNoArrows() {
        #expect(DaemonAPI.WorktreeStatus(uncommitted: 0, unmerged: 1).summary == "1 unmerged")
    }

    @Test func anOlderDaemonSendsNoStatus() throws {
        let json = #"{"name":"x","root":"file:///tmp/x","branch":"b","isProjectFolder":false,"exists":true,"madeByApp":true,"agents":[]}"#
        let summary = try JSONDecoder().decode(DaemonAPI.WorktreeSummary.self, from: Data(json.utf8))
        #expect(summary.status == nil)
    }

    @Test func itRoundTrips() throws {
        let summary = DaemonAPI.WorktreeSummary(
            name: "x", root: URL(filePath: "/tmp/x"), branch: "b", isProjectFolder: false,
            exists: true, madeByApp: true, agents: [], status: .init(uncommitted: 1, unmerged: 2))
        let back = try JSONDecoder().decode(DaemonAPI.WorktreeSummary.self, from: JSONEncoder().encode(summary))
        #expect(back == summary)
    }
}
