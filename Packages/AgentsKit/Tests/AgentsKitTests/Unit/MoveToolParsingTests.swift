import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// What `enter_worktree` and `exit_worktree` make of their arguments before the daemon
/// hears them (053, contracts/move.md §1).
@Suite("The move tools' arguments")
struct MoveToolParsingTests {
    private func read(_ name: String, _ arguments: JSONValue?) -> Result<AppService.MoveCall, AppService.AgentCallProblem>? {
        AppService.moveCall(named: "mcp__agents__" + name, arguments)
    }

    private func refusal(_ result: Result<AppService.MoveCall, AppService.AgentCallProblem>?) -> String? {
        if case .failure(let problem) = result { return problem.message }
        return nil
    }

    @Test func enteringWithNothingMakesANewWorktreeNamedFromTheTitle() throws {
        #expect(try read("enter_worktree", nil)?.get() == .move(target: .newWorktree(name: nil), removeLeft: false, discardChanges: false))
        #expect(try read("enter_worktree", [:])?.get() == .move(target: .newWorktree(name: nil), removeLeft: false, discardChanges: false))
    }

    @Test func aNameMakesANewOneAndAPathEntersOneThere() throws {
        #expect(try read("enter_worktree", ["name": "fix-login"])?.get()
                == .move(target: .newWorktree(name: "fix-login"), removeLeft: false, discardChanges: false))
        #expect(try read("enter_worktree", ["path": "/tmp/repo/.agents/worktrees/x"])?.get()
                == .move(target: .existing(URL(filePath: "/tmp/repo/.agents/worktrees/x", directoryHint: .isDirectory)),
                         removeLeft: false, discardChanges: false))
    }

    @Test func nameAndPathTogetherOrARelativePathAreRefused() {
        #expect(refusal(read("enter_worktree", ["name": "a", "path": "/tmp/b"])) == "Nothing was moved: give name for a new worktree or path for one already there, not both.")
        #expect(refusal(read("enter_worktree", ["path": "worktrees/b"])) == "Nothing was moved: path has to be an absolute path, starting at /.")
    }

    @Test func exitingNeedsAnAction() {
        #expect(refusal(read("exit_worktree", nil)) == "Nothing was moved: action has to be keep or remove.")
        #expect(refusal(read("exit_worktree", ["action": "delete"])) == "Nothing was moved: action has to be keep or remove.")
    }

    @Test func keepAndRemoveBothGoBackToTheProjectFolder() throws {
        #expect(try read("exit_worktree", ["action": "keep"])?.get() == .move(target: .projectFolder, removeLeft: false, discardChanges: false))
        #expect(try read("exit_worktree", ["action": "remove"])?.get() == .move(target: .projectFolder, removeLeft: true, discardChanges: false))
        #expect(try read("exit_worktree", ["action": "remove", "discard_changes": true])?.get()
                == .move(target: .projectFolder, removeLeft: true, discardChanges: true))
    }

    @Test func discardingGoesOnlyWithRemove() {
        #expect(refusal(read("exit_worktree", ["action": "keep", "discard_changes": true])) == "Nothing was moved: discard_changes only goes with action remove.")
    }

    @Test func otherToolsAreNotMoves() {
        #expect(read("finish_turn", nil) == nil)
        #expect(read("EnterWorktree", nil) == nil, "Claude's own is not ours")
    }

    /// The app tells tools apart by the end of their names, so no name may end with another.
    @Test func noToolNameEndsWithAnother() {
        let names = [AppTool.finishTurn, AppTool.showFile, AppTool.manageWorkflows, AppTool.startAgent,
                     AppTool.stopAgent, AppTool.archiveAgent, AppTool.listMyAgents, AppTool.leaseResource,
                     AppTool.listResources, AppTool.waitForEvent, AppTool.cancelWait,
                     AppTool.publishEvent, AppTool.pushPullRequest, AppTool.replyOnPullRequest,
                     AppTool.suggestPrompts, AppTool.reportOutcome]
        for move in [AppTool.enterWorktree, AppTool.exitWorktree] {
            for other in names + [AppTool.enterWorktree, AppTool.exitWorktree] where other != move {
                #expect(!move.hasSuffix(other) && !other.hasSuffix(move), "\(move) and \(other)")
            }
        }
    }

    @Test func bothAreListedForEveryAgent() async throws {
        let listed = AppService.tools(managesAgents: false).compactMap { $0["name"]?.stringValue }
        #expect(listed.contains(AppTool.enterWorktree) && listed.contains(AppTool.exitWorktree))
    }

    /// Not for an agent on a runtime that would forget its conversation in another folder.
    @Test func neitherIsListedWhenTheRuntimeCannotMove() {
        let listed = AppService.tools(managesAgents: true, movesItself: false).compactMap { $0["name"]?.stringValue }
        #expect(!listed.contains(AppTool.enterWorktree) && !listed.contains(AppTool.exitWorktree))
        #expect(listed.contains(AppTool.finishTurn))
    }

    /// Measured, 2026-09-26: these carried their conversation into another folder; Grok did not.
    @Test func theRuntimesThatMayMoveAreTheOnesMeasured() {
        #expect(RuntimeCatalog.carriesConversationAcrossFolders == ["claude", "copilot", "cursor", "codex"])
        #expect(!RuntimeCatalog.canMoveFolders(runtimeID: "grok"))
        #expect(RuntimeCatalog.whyCannotMoveFolders(runtimeID: "grok").hasPrefix("Grok can't carry"))
    }
}
