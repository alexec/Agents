import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// Workflow triggers and events are one vocabulary (042 US3, FR-021, FR-022, FR-025).
@Suite("Workflow triggers on events")
struct WorkflowTriggerEventTests {
    private let project = URL(fileURLWithPath: "/tmp/project")

    private func triggers(_ on: String) -> Workflow {
        WorkflowFile.parse("---\non:\n\(on)\n---\n\nDo it.\n", workflowID: "w", in: project)
    }

    @Test func todaysNamesReadExactlyAsTheyDid() {
        let workflow = triggers("""
              - agent-finished
              - agent-asked-permission
              - agent-asked-form
              - agent-stopped
              - workflow-completed
            """)
        #expect(workflow.problem == nil)
        #expect(workflow.triggers == [.agentFinished, .agentAskedPermission, .agentAskedForm, .agentStopped,
                                      .workflowCompleted(id: nil)])
    }

    @Test func dottedNamesAreEvents() {
        let workflow = triggers("""
              - mac.wake
              - custom.build_green
              - branch.*
              - branch.moved:
                  branch: main
            """)
        #expect(workflow.problem == nil)
        #expect(workflow.triggers == [.event(EventPattern("mac.wake")), .event(EventPattern("custom.build_green")),
                                      .event(EventPattern("branch.*")),
                                      .event(EventPattern("branch.moved", filters: ["branch": "main"]))])
    }

    @Test func aDetailTheKindDoesNotCarryIsAFileError() {
        let workflow = triggers("""
              - workflow.completed:
                  branch: main
            """)
        guard case .unreadable(let detail)? = workflow.problem else { Issue.record("not refused"); return }
        #expect(detail.contains("\"workflow.completed\" takes workflow, agent, outcome, not branch"))
    }

    @Test func aDottedNameThisVersionDoesNotKnowStaysInert() {
        let workflow = triggers("  - calendar.meeting_started")
        #expect(workflow.triggers == [.unrecognised(name: "calendar.meeting_started", keys: [:])])
        #expect(workflow.problem == .triggerNotSupported("calendar.meeting_started"))
    }

    @Test func anEventTriggerTravelsAsOneAnOlderDeviceDoesNotKnow() throws {
        let event = WorkflowTrigger.event(EventPattern("branch.moved", filters: ["branch": "main"]))
        let unknown = WorkflowTrigger.unrecognised(name: "branch.moved", keys: ["branch": .string("main")])
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        #expect(try encoder.encode(event) == encoder.encode(unknown),
                "the same bytes an older decoder already reads as a trigger it does not know")
        #expect(try JSONDecoder().decode(WorkflowTrigger.self, from: encoder.encode(event)) == event)
    }

    @Test func todaysNamesAnswerToTheirKinds() {
        #expect(WorkflowTrigger.agentFinished.patterns == [EventPattern("agent.finished")])
        #expect(Set(WorkflowTrigger.agentStopped.patterns.map(\.name)) == ["agent.stopped", "agent.failed"])
        #expect(WorkflowTrigger.workflowCompleted(id: "nightly").patterns
                == [EventPattern("workflow.completed", filters: ["workflow": "nightly"])])
        #expect(WorkflowTrigger.schedule(WorkflowExample.schedule).patterns.isEmpty)
    }

    @Test func onlyTheEventCaseMatchesEventsSoNothingFiresTwice() {
        let finished = Event(position: 1, name: "agent.finished", at: Date(), scope: .project(folder: project),
                             sentence: "")
        #expect(!WorkflowTrigger.agentFinished.matches(finished))
        #expect(WorkflowTrigger.event(EventPattern("agent.finished")).matches(finished))
    }

    @Test func anEventTriggerSaysWhatItWaitsFor() {
        #expect(WorkflowTrigger.event(EventPattern("mac.wake")).summary == "When this Mac woke up")
        #expect(WorkflowTrigger.event(EventPattern("custom.release_ready")).summary
                == "When an agent here publishes custom.release_ready")
    }
}
