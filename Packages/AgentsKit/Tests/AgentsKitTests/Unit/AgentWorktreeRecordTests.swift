import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// What an agent started in a worktree carries on its record, and which project it
/// belongs to (030).
@Suite("An agent in a worktree, on the record")
struct AgentWorktreeRecordTests {
    private let project = URL(filePath: "/tmp/repo")
    private var worktree: AgentWorktree {
        AgentWorktree(name: "fix-login",
                      root: URL(filePath: "/tmp/repo/.agents/worktrees/fix-login"),
                      branch: "agents/fix-login",
                      project: project,
                      base: "main",
                      madeByApp: true)
    }

    @Test func itsWorktreeSurvivesBeingSaved() throws {
        var agent = Agent(runtimeID: "claude", cwd: worktree.root)
        agent.worktree = worktree
        let read = try StoreCoding.decoder.decode(Agent.self, from: StoreCoding.encoder.encode(agent))
        #expect(read.worktree == worktree)
    }

    @Test func aRecordFromBeforeThisFeatureHasNoWorktreeAndBelongsToItsFolder() throws {
        let agent = Agent(runtimeID: "claude", cwd: project)
        let written = try StoreCoding.encoder.encode(agent)
        let json = try #require(try JSONSerialization.jsonObject(with: written) as? [String: Any])
        #expect(json["worktree"] == nil, "written only when there is one")
        let read = try StoreCoding.decoder.decode(Agent.self, from: written)
        #expect(read.worktree == nil)
        #expect(read.projectFolder == Project.standardize(project))
    }

    /// Working in the worktree, filed under the project it came from.
    @Test func anAgentInAWorktreeBelongsToItsProject() {
        var agent = Agent(runtimeID: "claude", cwd: worktree.root)
        agent.worktree = worktree
        #expect(agent.projectFolder == Project.standardize(project))
        #expect(agent.cwd == worktree.root)
    }

    @Test func theChoiceTravelsBothWays() throws {
        let choices: [WorktreeChoice] = [.new, .existing(URL(filePath: "/tmp/repo/.agents/worktrees/x"))]
        for choice in choices {
            let read = try JSONDecoder().decode(WorktreeChoice.self, from: JSONEncoder().encode(choice))
            #expect(read == choice)
        }
    }
}
