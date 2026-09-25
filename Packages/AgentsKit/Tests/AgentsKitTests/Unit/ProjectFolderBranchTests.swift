import Foundation
import Testing
@testable import AgentsKitCore

/// The worktree chooser says which branch the project folder is on, since it is not
/// always main.
@Suite("The project folder's branch, in the chooser")
struct ProjectFolderBranchTests {
    private func listed(branch: String?, isProjectFolder: Bool = true) -> DaemonAPI.WorktreesListResponse {
        DaemonAPI.WorktreesListResponse(isRepository: true, canMakeNew: true, worktrees: [
            DaemonAPI.WorktreeSummary(name: "repo", root: URL(filePath: "/tmp/repo"), branch: branch,
                                      isProjectFolder: isProjectFolder, exists: true,
                                      madeByApp: false, agents: []),
        ])
    }

    @Test func itsBranchComesFirst() {
        #expect(listed(branch: "feature/login").projectFolderDescription
                == "feature/login · work alongside anything else here")
    }

    @Test func aDetachedHeadIsSaid() {
        #expect(listed(branch: nil).projectFolderDescription.hasPrefix("detached · "))
    }

    @Test func theBranchIsNamedForTheFolderChip() {
        #expect(listed(branch: "feature/login").projectFolderBranch == "feature/login")
        #expect(listed(branch: nil).projectFolderBranch == "detached")
        #expect(DaemonAPI.WorktreesListResponse.notARepository.projectFolderBranch == nil)
    }

    @Test func beforeTheListArrivesItSaysWhatItAlwaysDid() {
        #expect(DaemonAPI.WorktreesListResponse(isRepository: true).projectFolderDescription
                == "Work alongside anything else here")
        #expect(listed(branch: "other", isProjectFolder: false).projectFolderDescription
                == "Work alongside anything else here")
    }
}
