import Foundation
import Testing
@testable import AgentsKitCore

/// Activity ▸ Worktrees (#790): the order, the words, and sizes heard after the list.
@Suite("Worktree tally")
struct WorktreeTallyTests {
    private static let gb: Int64 = 1_000_000_000

    private func worktree(_ name: String, gb: Double?, agents: Int = 0, partial: Bool = false,
                          in folder: String = "/p") -> DaemonAPI.WorktreeSummary {
        DaemonAPI.WorktreeSummary(
            name: name, root: URL(filePath: "\(folder)/.agents/worktrees/\(name)"), branch: "agents/\(name)",
            isFolderPath: false, exists: true, madeByApp: true, agents: (0..<agents).map { _ in UUID() },
            size: gb.map { DaemonAPI.WorktreeSize(bytes: Int64($0 * Double(Self.gb)), partial: partial) })
    }

    @Test func idleOnesComeFirstLargestFirstThenUnmeasuredThenByName() {
        let listed = [worktree("busy-big", gb: 9, agents: 1), worktree("b", gb: nil), worktree("small", gb: 1),
                      worktree("a", gb: nil), worktree("big", gb: 5)]
        #expect(listed.sorted(by: DaemonAPI.WorktreeSummary.cleanupOrder).map(\.name)
                == ["big", "small", "a", "b", "busy-big"])
    }

    @Test func thePageSaysHowMuchAndHowMuchIsIdle() {
        let tally = WorktreeTally([worktree("a", gb: 9, agents: 1), worktree("b", gb: 3, partial: true), worktree("c", gb: nil)])
        #expect(tally.rowWords == "3 worktrees, 2 idle")
        #expect(tally.pageLine == "Worktrees hold over 12.0 GB, 3.0 GB of it idle.")
        #expect(WorktreeTally([worktree("c", gb: nil)]).pageLine == "Measuring 1 worktree…")
        #expect(WorktreeTally([DaemonAPI.WorktreeSummary]()).pageLine == WorktreeTally.empty)
        #expect(WorktreeTally([DaemonAPI.WorktreeSummary]()).rowWords == nil)
    }

    @Test func removeBuildOutputSaysWhatItFreed() {
        #expect(WorktreeTally.freedWords(.init(removed: ["build", "Web/node_modules"],
                                               freed: .init(bytes: 3_200_000_000)))
                == "Freed 3.2 GB: build, Web/node_modules.")
        #expect(WorktreeTally.freedWords(.init(removed: [], freed: .init(bytes: 0))) == "No build output to remove.")
    }

    @MainActor
    @Test func aSizeHeardAfterTheListFillsItInAndFoldersHoldingMostIdleComeFirst() {
        let model = AgentsModel()
        let late = worktree("late", gb: nil, in: "/q")
        model.replaceWorktrees([
            DaemonAPI.FolderWorktrees(folder: URL(filePath: "/p"), worktrees: [worktree("a", gb: 2)]),
            DaemonAPI.FolderWorktrees(folder: URL(filePath: "/q"), worktrees: [late]),
        ])
        #expect(model.worktreesForCleanup().map(\.folder.path) == ["/p", "/q"])

        let note = DaemonAPI.WorktreesSized(sizes: [.init(root: late.root, size: .init(bytes: 7 * Self.gb))])
        #expect(model.apply(DaemonAPI.Notification.worktreesSized, try? JSONValue.encoding(note)))
        #expect(model.size(of: late)?.bytes == 7 * Self.gb)
        #expect(model.worktreesForCleanup().map(\.folder.path) == ["/q", "/p"])
    }
}
