import Foundation
import Testing
@testable import AgentsKitCore

/// The worktree chooser says which branch the folder is on, since it is not
/// always main.
@Suite("The folder's branch, in the chooser")
struct FolderPathBranchTests {
    private func listed(branch: String?, isFolderPath: Bool = true) -> DaemonAPI.WorktreesListResponse {
        DaemonAPI.WorktreesListResponse(isRepository: true, canMakeNew: true, worktrees: [
            DaemonAPI.WorktreeSummary(name: "repo", root: URL(filePath: "/tmp/repo"), branch: branch,
                                      isFolderPath: isFolderPath, exists: true,
                                      madeByApp: false, agents: []),
        ])
    }

    @Test func itsBranchComesFirst() {
        #expect(listed(branch: "feature/login").folderPathDescription
                == "feature/login · work alongside anything else here")
    }

    @Test func aDetachedHeadIsSaid() {
        #expect(listed(branch: nil).folderPathDescription.hasPrefix("detached · "))
    }

    @Test func theBranchIsNamedForTheFolderChip() {
        #expect(listed(branch: "feature/login").folderPathBranch == "feature/login")
        #expect(listed(branch: nil).folderPathBranch == "detached")
        #expect(DaemonAPI.WorktreesListResponse.notARepository.folderPathBranch == nil)
    }

    @Test func beforeTheListArrivesItSaysWhatItAlwaysDid() {
        #expect(DaemonAPI.WorktreesListResponse(isRepository: true).folderPathDescription
                == "Work alongside anything else here")
        #expect(listed(branch: "other", isFolderPath: false).folderPathDescription
                == "Work alongside anything else here")
    }
}
