import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// The three pull-request triggers in a file and on the wire (038 R11).
@Suite("Pull-request triggers, read and written")
struct WorkflowTriggerCodingTests {
    private let project = URL(filePath: "/tmp/a-project")

    private let babysitter = """
        ---
        name: Babysit my pull requests
        on:
          - pull-request-checks-failed
          - pull-request-review-comments
          - pull-request-conflicts
        agent: new
        ---
        Read what changed.
        """

    @Test func theThreeNamesReadFromAFile() {
        let workflow = WorkflowFile.parse(babysitter, workflowID: "babysit-pull-requests", in: project)
        #expect(workflow.problem == nil)
        #expect(workflow.triggers == WorkflowTrigger.pullRequestTriggers)
        #expect(workflow.canFire)
        #expect(workflow.respondsToPullRequests)
        #expect(workflow.onlyRespondsToPullRequests)
    }

    @Test func allThreeTogetherReadAsOneSentence() {
        let workflow = WorkflowFile.parse(babysitter, workflowID: "babysit-pull-requests", in: project)
        #expect(workflow.summary.hasPrefix(
            "When one of my pull requests fails its checks, gets review comments or conflicts with its base, in a new agent"))
    }

    @Test func oneOnItsOwnSaysItsOwnWords() {
        let workflow = Workflow(workflowID: "w", folder: project,
                                triggers: [.pullRequestConflicts, .agentFinished])
        #expect(workflow.summary.hasPrefix(
            "When one of my pull requests conflicts with its base, and When an agent finishes"))
        #expect(!workflow.onlyRespondsToPullRequests)
    }

    @Test func aPullRequestTriggerWithSettingsIsUnreadable() {
        let text = """
            ---
            on:
              - pull-request-checks-failed:
                  branch: main
            ---
            Fix it.
            """
        let workflow = WorkflowFile.parse(text, workflowID: "w", in: project)
        guard case .unreadable(let detail) = workflow.problem else {
            Issue.record("expected unreadable, got \(String(describing: workflow.problem))")
            return
        }
        #expect(detail.contains("takes no settings"))
    }

    @Test func theyRoundTripThroughJSON() throws {
        let all = WorkflowTrigger.pullRequestTriggers + [.agentFinished, .workflowCompleted(id: "x")]
        let data = try JSONEncoder().encode(all)
        #expect(try JSONDecoder().decode([WorkflowTrigger].self, from: data) == all)
    }

    /// What an older build sees: the same shape its own `.unrecognised` has, so it
    /// lists the workflow as inert rather than failing to read the project's workflows.
    @Test func anOlderReaderSeesATriggerItDoesNotKnow() throws {
        enum OldTrigger: Codable, Equatable {
            case agentFinished
            case unrecognised(name: String, keys: [String: JSONValue])
        }
        let data = try JSONEncoder().encode(WorkflowTrigger.pullRequestChecksFailed)
        #expect(try JSONDecoder().decode(OldTrigger.self, from: data)
                == .unrecognised(name: "pull-request-checks-failed", keys: [:]))
    }

    @Test func existingTriggersKeepTheirShape() throws {
        let data = try JSONEncoder().encode(WorkflowTrigger.agentFinished)
        #expect(String(decoding: data, as: UTF8.self) == #"{"agentFinished":{}}"#)
    }

    @Test func aStateWrittenBeforeStandingAgentsPerPullRequestStillReads() throws {
        let json = #"{"folder":"file:///tmp/a-project","workflowID":"w","isArchived":true}"#
        let state = try JSONDecoder().decode(WorkflowState.self, from: Data(json.utf8))
        #expect(state.isArchived)
        #expect(state.standingAgentIDs.isEmpty)
    }

    @Test func refusalsCollapseForEachPullRequest() {
        #expect(WorkflowRefusal.worktreeDirty(pr: 3).isSameReason(as: .worktreeDirty(pr: 3)))
        #expect(!WorkflowRefusal.worktreeDirty(pr: 3).isSameReason(as: .worktreeDirty(pr: 4)))
        #expect(WorkflowRefusal.babysittingStopped(pr: 3, runs: 3).needsAPerson)
        #expect(!WorkflowRefusal.noWorktree(pr: 3).needsAPerson)
        #expect(WorkflowRefusal.worktreeDirty(pr: 377).rowMessage == "its worktree has uncommitted changes")
        #expect(WorkflowRefusal.worktreeDirty(pr: 377).message == "#377's worktree has uncommitted changes")
    }
}
