import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// What the move arguments make of themselves before the daemon hears them (053,
/// contracts/move.md §1): on `move_worktree` since #481, and on `finish_turn` as before.
@Suite("The move arguments")
struct MoveToolParsingTests {
    private func read(_ arguments: JSONValue?) -> Result<AppService.MoveCall?, AppService.AgentCallProblem> {
        AppService.moveCall(arguments)
    }

    private func refusal(_ result: Result<AppService.MoveCall?, AppService.AgentCallProblem>) -> String? {
        if case .failure(let problem) = result { return problem.message }
        return nil
    }

    @Test func noMoveArgumentsAskForNoMove() throws {
        #expect(try read(nil).get() == nil)
        #expect(try read(["outcome": "done", "message": "Done."]).get() == nil)
        #expect(try read(["worktree": "  "]).get() == nil, "a blank name is no name")
    }

    @Test func aNameMakesANewOneAndAPathEntersOneThere() throws {
        #expect(try read(["worktree": "fix-login"]).get()
                == .move(target: .newWorktree(name: "fix-login"), removeLeft: false, discardChanges: false))
        #expect(try read(["worktree": "/tmp/repo/.agents/worktrees/x"]).get()
                == .move(target: .existing(URL(filePath: "/tmp/repo/.agents/worktrees/x", directoryHint: .isDirectory)),
                         removeLeft: false, discardChanges: false))
    }

    @Test func enteringAndLeavingTogetherAreRefused() {
        #expect(refusal(read(["worktree": "a", "leave_worktree": "keep"]))
                == "Nothing was recorded: give worktree to move into one, or leave_worktree to go back to the project folder, not both.")
    }

    @Test func leavingNeedsKeepOrRemove() {
        #expect(refusal(read(["leave_worktree": "delete"])) == "Nothing was recorded: leave_worktree has to be keep or remove.")
    }

    @Test func keepAndRemoveBothGoBackToTheProjectFolder() throws {
        #expect(try read(["leave_worktree": "keep"]).get() == .move(target: .projectFolder, removeLeft: false, discardChanges: false))
        #expect(try read(["leave_worktree": "remove"]).get() == .move(target: .projectFolder, removeLeft: true, discardChanges: false))
        #expect(try read(["leave_worktree": "remove", "discard_changes": true]).get()
                == .move(target: .projectFolder, removeLeft: true, discardChanges: true))
    }

    @Test func discardingGoesOnlyWithRemove() {
        let words = "Nothing was recorded: discard_changes only goes with leave_worktree remove."
        #expect(refusal(read(["leave_worktree": "keep", "discard_changes": true])) == words)
        #expect(refusal(read(["worktree": "a", "discard_changes": true])) == words)
        #expect(refusal(read(["discard_changes": true])) == words)
    }

    /// Its own tool since #481, offered to every agent whose runtime can move, and the
    /// slim `finish_turn` lists none of the move arguments (it still reads them).
    @Test func moveWorktreeCarriesTheMoveForEveryAgent() {
        let listed = AppService.tools(managesAgents: false)
        let names = listed.compactMap { $0["name"]?.stringValue }
        #expect(!names.contains("enter_worktree") && !names.contains("exit_worktree"))
        let move = listed.first { $0["name"]?.stringValue == AppTool.moveWorktree }
        for key in ["worktree", "leave_worktree", "discard_changes"] {
            #expect(move?["inputSchema"]?["properties"]?[key] != nil, "\(key)")
        }
        let finish = listed.first { $0["name"]?.stringValue == AppTool.finishTurn }
        #expect(finish?["inputSchema"]?["properties"]?["worktree"] == nil)
    }

    /// Not for an agent on a runtime that would forget its conversation in another folder.
    @Test func noMoveIsOfferedWhenTheRuntimeCannotMove() {
        let listed = AppService.tools(managesAgents: true, movesItself: false)
        #expect(!listed.contains { $0["name"]?.stringValue == AppTool.moveWorktree })
        #expect(listed.contains { $0["name"]?.stringValue == AppTool.finishTurn })
    }

    /// No argument at all is the agent taking its move back (#481).
    @Test func moveWorktreeWithNothingTakesTheMoveBack() throws {
        let call = try #require(AppService.selfCall(named: "mcp__agents__move_worktree", [:], movesItself: true))
        #expect(try call.get() == .move(nil))
        let refused = try #require(AppService.selfCall(named: "move_worktree", ["leave_worktree": "remove"],
                                                       movesItself: false))
        guard case .failure(let problem) = refused else { Issue.record("moved on a runtime that cannot"); return }
        #expect(problem.message.contains("cannot carry its conversation"))
    }

    /// Measured, 2026-09-26: these carried their conversation into another folder; Grok did not.
    @Test func theRuntimesThatMayMoveAreTheOnesMeasured() {
        #expect(RuntimeCatalog.carriesConversationAcrossFolders == ["claude", "copilot", "cursor", "codex"])
        #expect(!RuntimeCatalog.canMoveFolders(runtimeID: "grok"))
        #expect(RuntimeCatalog.whyCannotMoveFolders(runtimeID: "grok").hasPrefix("Grok can't carry"))
    }
}
