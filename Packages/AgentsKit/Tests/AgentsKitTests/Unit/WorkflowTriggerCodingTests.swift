import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// What the pull-request triggers (038) left behind once GitHub support was removed: a
/// file that still names them is listed and inert, and the app's own records of them
/// still read.
@Suite("Pull-request triggers, after GitHub support went")
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

    @Test func theOldNamesReadAsTriggersThisVersionDoesNotKnow() {
        let workflow = WorkflowFile.parse(babysitter, workflowID: "babysit-pull-requests", in: project)
        #expect(workflow.triggers == [
            .unrecognised(name: "pull-request-checks-failed", keys: [:]),
            .unrecognised(name: "pull-request-review-comments", keys: [:]),
            .unrecognised(name: "pull-request-conflicts", keys: [:]),
        ])
        #expect(workflow.problem == .triggerNotSupported("pull-request-checks-failed"))
        #expect(!workflow.canFire)
    }

    @Test func oneBesideAKnownTriggerLeavesThatOneWorking() {
        let text = """
            ---
            on:
              - pull-request-conflicts
              - agent.finished
            ---
            Look.
            """
        let workflow = WorkflowFile.parse(text, workflowID: "w", in: project)
        #expect(workflow.problem == nil)
        #expect(workflow.supportedTriggers == [.event(EventPattern("agent.finished"))])
    }

    /// What an older build wrote on the wire comes back as the same inert trigger, so
    /// writing it back does not quietly delete it.
    @Test func anOldTriggerOnTheWireStaysWhole() throws {
        let data = Data(#"{"unrecognised":{"name":"pull-request-checks-failed","keys":{}}}"#.utf8)
        let trigger = try JSONDecoder().decode(WorkflowTrigger.self, from: data)
        #expect(trigger == .unrecognised(name: "pull-request-checks-failed", keys: [:]))
        #expect(try JSONDecoder().decode(WorkflowTrigger.self, from: JSONEncoder().encode(trigger)) == trigger)
    }

    @Test func existingTriggersKeepTheirShape() throws {
        let data = try JSONEncoder().encode(WorkflowTrigger.unrecognised(name: "x", keys: [:]))
        #expect(String(decoding: data, as: UTF8.self) == #"{"unrecognised":{"name":"x","keys":{}}}"#)
    }

    /// A state written while a pull request's run was refused: the refusal is one this
    /// version no longer has, so it is forgotten, and the rest of the state is kept.
    @Test func aStateWithAPullRequestRefusalStillReads() throws {
        let json = """
            {"folder":"file:///tmp/a-project","workflowID":"w","isArchived":true,
             "standingAgentIDs":{"3":"\(UUID().uuidString)"},
             "lastOutcome":{"refused":{"_0":{"babysittingStopped":{"pr":3,"runs":3}},"at":0,"repeats":1}}}
            """
        let state = try JSONDecoder().decode(WorkflowState.self, from: Data(json.utf8))
        #expect(state.legacy?.isArchived == true)
        #expect(state.lastOutcome == nil)
    }
}
