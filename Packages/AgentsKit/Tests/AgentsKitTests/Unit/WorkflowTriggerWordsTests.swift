import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// What the workflow page's Triggers section says about each trigger (#98).
@Suite("The words for a workflow's triggers")
struct WorkflowTriggerWordsTests {
    private let project = URL(fileURLWithPath: "/tmp/words-project")

    @Test func eachTriggerListensWhereItsEventsAre() {
        #expect(WorkflowTrigger.event(EventPattern("agent.finished")).listensIn == .project)
        #expect(WorkflowTrigger.event(EventPattern("branch.moved")).listensIn == .project)
        #expect(WorkflowTrigger.event(EventPattern("mac.wake")).listensIn == .mac)
        #expect(WorkflowTrigger.event(EventPattern("cost.limit_reached")).listensIn == .either)
        #expect(WorkflowTrigger.event(EventPattern("custom.build_green")).listensIn == .project)
        // A whole subject that mixes the two is either.
        #expect(WorkflowTrigger.event(EventPattern("cost.*")).listensIn == .either)
        #expect(WorkflowTrigger.event(EventPattern("agent.*")).listensIn == .project)
        #expect(WorkflowTrigger.schedule(WorkflowSchedule()).listensIn == nil)
        #expect(WorkflowTrigger.unrecognised(name: "x", keys: [:]).listensIn == nil)
    }

    @Test func filtersAreTheFilesOwn() {
        #expect(WorkflowTrigger.event(EventPattern("branch.moved", filters: ["branch": "main"])).filters
                == ["branch": "main"])
        #expect(WorkflowTrigger.event(EventPattern("agent.finished")).filters.isEmpty)
    }

    @Test func aTriggeringRunSaysWhichAgentItResumesOrThatThereIsNone() {
        #expect(WorkflowTrigger.event(EventPattern("custom.ready")).resumedAgent
                == "Resumes the agent that published it")
        #expect(WorkflowTrigger.event(EventPattern("mac.wake")).resumedAgent.contains("never runs"))
        #expect(WorkflowTrigger.schedule(WorkflowSchedule()).resumedAgent.contains("never runs"))
        #expect(WorkflowTrigger.event(EventPattern("agent.started")).resumedAgent == "Resumes the agent it is about")
    }

    @Test func whatSetARunOffReadsAfterLastRan() {
        #expect(WorkflowCause.byHand.phrase == "by hand, with Run now")
        #expect(WorkflowCause.trigger(.schedule(WorkflowSchedule())).phrase == "on its schedule")
        #expect(WorkflowCause.trigger(.event(EventPattern("branch.moved", filters: ["branch": "main"]))).phrase
                == "on branch.moved branch main")
        #expect(WorkflowCause.trigger(.unrecognised(name: "agent-finished", keys: [:])).phrase
                == "waits for \"agent-finished\", which this version does not know about yet. Did you mean agent.finished?")
    }

    @Test func aBrokenFileStillShowsTheTriggersItCouldRead() {
        let file = WorkflowFile.parse("""
            ---
            name: Broken options
            on:
              - schedule:
                  at: [":30"]
              - custom.build_green
            options:
              - fast
            ---

            Deploy.
            """, workflowID: "broken", in: project)
        guard case .unreadable = file.problem else { Issue.record("expected it to be broken"); return }
        #expect(file.name == "Broken options")
        #expect(file.triggers.count == 2)
        // Shown, never acted on.
        #expect(!file.canFire)
        #expect(file.nextDue(after: Date()) == nil)
    }

    @Test func aFileWithNoReadableTriggersHasNone() {
        let file = WorkflowFile.parse("---\non: [\n---\n\nGo.\n", workflowID: "bad", in: project)
        #expect(file.problem != nil)
        #expect(file.triggers.isEmpty)
    }
}
