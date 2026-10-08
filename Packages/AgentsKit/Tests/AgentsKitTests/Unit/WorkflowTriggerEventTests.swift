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

    @Test func aNameAboutTheAppsOwnSubjectThisVersionDoesNotKnowStaysInert() {
        let workflow = triggers("  - branch.created")
        #expect(workflow.triggers == [.unrecognised(name: "branch.created", keys: [:])])
        #expect(workflow.problem == .triggerNotSupported("branch.created"))
    }

    /// Any other `noun.verbed` name is an MCP server's event (#383).
    @Test func aDottedNameAboutAnythingElseIsAServersEvent() {
        let workflow = triggers("  - calendar.meeting_started")
        #expect(workflow.triggers == [.serverEvent(MCPEventTrigger(event: "calendar.meeting_started"))])
        #expect(workflow.problem == nil)
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

    // MARK: 073

    @Test func aDetailTakesAListInlineOrAsABlock() {
        let workflow = triggers("""
              - agent.finished:
                  outcome: [done, nothing_to_do]
              - agent.failed:
                  reason:
                    - allowance_spent
                    - its allowance ran out
                    - rate_limited
              - agent.finished:
                  labels: bug
                  afterwards: park
            """)
        #expect(workflow.problem == nil)
        #expect(workflow.triggers == [
            .event(EventPattern("agent.finished", filters: ["outcome": DetailFilter(anyOf: ["done", "nothing_to_do"])!])),
            .event(EventPattern("agent.failed", filters: [
                "reason": DetailFilter(anyOf: ["allowance_spent", "rate_limited"])!])),
            .event(EventPattern("agent.finished", filters: ["labels": "bug", "afterwards": "park"])),
        ])
    }

    @Test func aWrongValueIsTheFilesProblemNamingTheRightOnes() {
        let workflow = triggers("""
              - agent.finished:
                  outcome: complete
            """)
        #expect(workflow.problem == .unreadable("outcome on agent.finished is one of done, nothing_to_do, "
                                                + "needs_answer, partly_done, stuck, blocked; \"complete\" is not one of them."))
        let mapping = triggers("""
              - agent.finished:
                  outcome:
                    done: yes
            """)
        guard case .unreadable(let detail)? = mapping.problem else { Issue.record("not refused"); return }
        #expect(detail.contains("should be one value or a list of values"))
    }

    @Test func theTriggerTextAPatternWritesReadsBackAsTheSamePattern() throws {
        for pattern in [EventPattern("agent.finished", filters: ["outcome": DetailFilter(anyOf: ["done", "nothing_to_do"])!,
                                                                 "labels": "needs review"]),
                        EventPattern("lease.released", filters: ["resource": "simulator", "how": "expired"])] {
            let lines = pattern.asTrigger.split(separator: "\n").dropFirst().joined(separator: "\n")
            let workflow = triggers(lines)
            #expect(workflow.triggers == [.event(pattern)], "\(pattern.asTrigger)")
        }
    }

    @Test func aListTravelsAsAnArrayAndAnOlderReaderShowsItWider() throws {
        let trigger = WorkflowTrigger.event(EventPattern("agent.finished", filters: [
            "outcome": DetailFilter(anyOf: ["done", "nothing_to_do"])!, "labels": "bug"]))
        let data = try JSONEncoder().encode(trigger)
        let wire = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(wire["unrecognised"]?["keys"]?["outcome"] == .array([.string("done"), .string("nothing_to_do")]))
        #expect(wire["unrecognised"]?["keys"]?["labels"] == .string("bug"))
        #expect(try JSONDecoder().decode(WorkflowTrigger.self, from: data) == trigger)
        // An older reader kept scalars only, so it read the trigger without the list.
        let keys = wire["unrecognised"]?["keys"]?.objectValue ?? [:]
        #expect(keys.compactMapValues(WorkflowTrigger.scalar) == ["labels": "bug"])
    }
}
