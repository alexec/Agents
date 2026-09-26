import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// A move asked for and not yet made, on the agent's record (053).
@Suite("A waiting move, on the record")
struct AgentMoveRecordTests {
    private let project = URL(filePath: "/tmp/repo")
    private let asked = Date(timeIntervalSince1970: 1_790_000_000)
    private let targets: [MoveTarget] = [
        .newWorktree(name: nil),
        .newWorktree(name: "fix-login"),
        .existing(URL(filePath: "/tmp/repo/.agents/worktrees/x")),
        .projectFolder,
    ]

    @Test func aWaitingMoveSurvivesBeingSaved() throws {
        for target in targets {
            var agent = Agent(runtimeID: "claude", cwd: project)
            agent.pendingMove = PendingMove(target: target, removeLeft: target == .projectFolder,
                                            discardChanges: false, askedBy: .agent, askedAt: asked)
            let read = try StoreCoding.decoder.decode(Agent.self, from: StoreCoding.encoder.encode(agent))
            #expect(read.pendingMove == agent.pendingMove)
        }
    }

    @Test func aRecordWithoutOneHasNone() throws {
        let agent = Agent(runtimeID: "claude", cwd: project)
        let written = try StoreCoding.encoder.encode(agent)
        let json = try #require(try JSONSerialization.jsonObject(with: written) as? [String: Any])
        #expect(json["pendingMove"] == nil, "written only when there is one")
        #expect(try StoreCoding.decoder.decode(Agent.self, from: written).pendingMove == nil)
    }

    /// A record written before 053, with a worktree from 030, still reads.
    @Test func aRecordFromBeforeThisFeatureStillReads() throws {
        var agent = Agent(runtimeID: "claude", cwd: URL(filePath: "/tmp/repo/.agents/worktrees/a"))
        agent.worktree = AgentWorktree(name: "a", root: agent.cwd, branch: "agents/a", project: project,
                                       base: "main", madeByApp: true)
        var json = try #require(try JSONSerialization.jsonObject(with: StoreCoding.encoder.encode(agent)) as? [String: Any])
        json.removeValue(forKey: "pendingMove")
        let read = try StoreCoding.decoder.decode(Agent.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(read.worktree == agent.worktree)
        #expect(read.pendingMove == nil)
    }

    /// One that cannot be read is dropped rather than losing the agent.
    @Test func anUnreadableOneIsDroppedNotTheAgent() throws {
        let agent = Agent(runtimeID: "claude", cwd: project)
        var json = try #require(try JSONSerialization.jsonObject(with: StoreCoding.encoder.encode(agent)) as? [String: Any])
        json["pendingMove"] = ["target": "somewhere new"]
        let read = try StoreCoding.decoder.decode(Agent.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(read.id == agent.id)
        #expect(read.pendingMove == nil)
    }

    @Test func everyTargetTravelsBothWays() throws {
        for target in targets {
            #expect(try JSONDecoder().decode(MoveTarget.self, from: JSONEncoder().encode(target)) == target)
        }
    }
}
