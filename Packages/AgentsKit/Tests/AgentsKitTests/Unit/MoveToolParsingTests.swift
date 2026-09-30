import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// What `finish_turn`'s move arguments make of themselves before the daemon hears them
/// (053, contracts/move.md §1).
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

    /// The move rides on the call that ends the turn: there are no tools of its own.
    @Test func finishTurnCarriesTheMoveForEveryAgent() {
        let listed = AppService.tools(managesAgents: false)
        let names = listed.compactMap { $0["name"]?.stringValue }
        #expect(!names.contains("enter_worktree") && !names.contains("exit_worktree"))
        let finish = listed.first { $0["name"]?.stringValue == AppTool.finishTurn }
        for key in AppService.movingArguments {
            #expect(finish?["inputSchema"]?["properties"]?[key] != nil, "\(key)")
        }
        #expect(finish?["description"]?.stringValue?.contains("leave_worktree") == true)
    }

    /// Not for an agent on a runtime that would forget its conversation in another folder.
    @Test func noMoveIsOfferedWhenTheRuntimeCannotMove() {
        let listed = AppService.tools(managesAgents: true, movesItself: false)
        let finish = listed.first { $0["name"]?.stringValue == AppTool.finishTurn }
        for key in AppService.movingArguments {
            #expect(finish?["inputSchema"]?["properties"]?[key] == nil, "\(key)")
        }
        #expect(finish?["inputSchema"]?["properties"]?["outcome"] != nil)
        let description = finish?["description"]?.stringValue ?? ""
        #expect(!description.contains("worktree"))
        #expect(description.hasSuffix("It is how you end."))
    }

    /// Measured, 2026-09-26: these carried their conversation into another folder; Grok did not.
    @Test func theRuntimesThatMayMoveAreTheOnesMeasured() {
        #expect(RuntimeCatalog.carriesConversationAcrossFolders == ["claude", "copilot", "cursor", "codex"])
        #expect(!RuntimeCatalog.canMoveFolders(runtimeID: "grok"))
        #expect(RuntimeCatalog.whyCannotMoveFolders(runtimeID: "grok").hasPrefix("Grok can't carry"))
    }
}
