import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// Whether a workflow may fire, and what is recorded when it may not.
///
/// The decision is a pure function, which is the point: every refusal in the spec is a
/// row in this table rather than something needing a daemon and a clock to demonstrate.
@Suite("Whether a workflow may fire")
struct WorkflowOutcomeTests {
    private func workflow(mode: WorkflowMode = .new,
                          triggers: [WorkflowTrigger] = [.agentFinished],
                          problem: WorkflowProblem? = nil) -> Workflow {
        Workflow(workflowID: "w", folder: URL(filePath: "/tmp/p"),
                 triggers: triggers, mode: mode, prompt: "go", problem: problem)
    }

    private func refusal(_ workflow: Workflow, isRunning: Bool = false, depth: Int = 0,
                         isArchived: Bool = false, overLimit: WorkflowLimit? = nil,
                         folderExists: Bool = true,
                         triggeringAgentIsUsable: Bool? = nil) -> WorkflowRefusal? {
        workflow.refusalIfBlocked(isRunning: isRunning, depth: depth,
                                  isArchived: isArchived, overLimit: overLimit,
                                  folderExists: folderExists,
                                  triggeringAgentIsUsable: triggeringAgentIsUsable)
    }

    @Test func anOrdinaryWorkflowMayFire() {
        #expect(refusal(workflow()) == nil)
    }

    @Test func aRunStillGoingBlocksTheNextFire() {
        #expect(refusal(workflow(), isRunning: true) == .runInFlight)
    }

    @Test func archivingBlocksIt() {
        #expect(refusal(workflow(), isArchived: true) == .archived)
    }

    @Test func eitherCeilingBlocksIt() {
        #expect(refusal(workflow(), overLimit: .project) == .overLimit(.project))
        #expect(refusal(workflow(), overLimit: .total) == .overLimit(.total))
    }

    @Test func aDecisionOfThePersonsOutranksEverythingElseWrongWithIt() {
        // Archived beats a file that cannot be read: they said they did not want it,
        // and fixing the file would not change that.
        #expect(refusal(workflow(problem: .unreadable("line 3")), isArchived: true) == .archived)
    }

    @Test func aChainDeeperThanTheLimitIsRefused() {
        #expect(refusal(workflow(), depth: Workflow.chainDepthLimit) == nil)
        #expect(refusal(workflow(), depth: Workflow.chainDepthLimit + 1)
                == .chainTooDeep(depth: Workflow.chainDepthLimit))
    }

    @Test func aMissingFolderIsRefusedBeforeAnythingElse() {
        #expect(refusal(workflow(), folderExists: false) == .folderGone)
    }

    @Test func anUnreadableFileNeverFires() {
        let broken = workflow(problem: .unreadable("Line 3: that is not a mapping"))
        #expect(refusal(broken) == .unreadable("Line 3: that is not a mapping"))
    }

    @Test func aTriggerFromTheFutureNeverFiresOnItsOwn() {
        let future = workflow(triggers: [.unrecognised(name: "deploys-finished", keys: [:])],
                              problem: .triggerNotSupported("deploys-finished"))
        #expect(refusal(future) == .triggerNotSupported(name: "deploys-finished"))
    }

    @Test func triggeringModeWithNoTriggeringAgentIsRefused() {
        // A schedule, or Run now, in `triggering` mode: there is nothing to resume.
        #expect(refusal(workflow(mode: .triggering)) == .noTriggeringAgent)
    }

    @Test func triggeringModeWithAnUnusableAgentIsRefusedRatherThanSubstituted() {
        #expect(refusal(workflow(mode: .triggering), triggeringAgentIsUsable: false)
                == .agentUnavailable)
    }

    @Test func triggeringModeWithAUsableAgentMayFire() {
        #expect(refusal(workflow(mode: .triggering), triggeringAgentIsUsable: true) == nil)
    }

    // MARK: Collapsing repeats

    @Test func theSameReasonTwiceCountsUp() {
        let first = WorkflowOutcome.refused(.runInFlight, at: Date(), repeats: 1)
        let second = WorkflowOutcome.refused(.runInFlight, at: Date(), repeats: 1).following(first)
        #expect(second == .refused(.runInFlight, at: second.at, repeats: 2))
    }

    @Test func aDifferentReasonStartsAgain() {
        let first = WorkflowOutcome.refused(.runInFlight, at: Date(), repeats: 4)
        let second = WorkflowOutcome.refused(.archived, at: Date(), repeats: 1).following(first)
        #expect(second == .refused(.archived, at: second.at, repeats: 1))
    }

    @Test func aRunReplacesTheCountEntirely() {
        let first = WorkflowOutcome.refused(.missedWhileClosed, at: Date(), repeats: 14)
        let id = UUID()
        let second = WorkflowOutcome.ran(agentID: id, at: Date()).following(first)
        #expect(second == .ran(agentID: id, at: second.at))
    }

    @Test func aLoopAtDifferentDepthsIsStillOneThingHappening() {
        // The depth is not part of the reason: three loop refusals are one problem that
        // keeps happening, not three separate ones.
        #expect(WorkflowRefusal.chainTooDeep(depth: 3).isSameReason(as: .chainTooDeep(depth: 4)))
    }

    @Test func aSettingRefusedTwiceIsOneThingHappening() {
        // The sentence names what the runtime offers, and that list can change between
        // two fires that are the same problem. The setting is the reason; the detail is
        // only how it was explained at the time.
        let first = WorkflowRefusal.settingRefused(
            setting: "permission-mode",
            detail: "\"plan\" is not a permission mode Claude offers here — it offers default")
        let again = WorkflowRefusal.settingRefused(
            setting: "permission-mode",
            detail: "\"plan\" is not a permission mode Claude offers here — it offers default, acceptEdits")
        #expect(first.isSameReason(as: again))

        // A different setting is a different problem, even on the same workflow.
        let model = WorkflowRefusal.settingRefused(setting: "model", detail: "…")
        #expect(!first.isSameReason(as: model))
    }

    @Test func aWeekendOfRefusedSettingsIsOneRowWithACount() {
        let refusal = WorkflowRefusal.settingRefused(setting: "permission-mode", detail: "no plan mode here")
        let first = WorkflowOutcome.refused(refusal, at: Date(), repeats: 1)
        let second = WorkflowOutcome.refused(refusal, at: Date(), repeats: 1).following(first)
        #expect(second == .refused(refusal, at: second.at, repeats: 2))
        #expect(second.summary == "Did not run 2 times — no plan mode here")
    }

    @Test func aFortnightAwayReadsAsOneLine() {
        let outcome = WorkflowOutcome.refused(.missedWhileClosed, at: Date(), repeats: 14)
        #expect(outcome.summary == "Missed 14 times — the app was closed")
    }

    // MARK: Which refusals want a person

    @Test func onlyTheRefusalsThatWillNotResolveThemselvesWantAPerson() {
        // The app's rule is that colour means somebody is needed. A workflow skipping
        // one fire is information; a loop that will keep happening is not.
        #expect(WorkflowRefusal.chainTooDeep(depth: 3).needsAPerson)
        #expect(WorkflowRefusal.unreadable("x").needsAPerson)
        #expect(WorkflowRefusal.folderGone.needsAPerson)
        // A ceiling is the other kind that keeps happening: nothing frees it but
        // somebody archiving another workflow.
        #expect(WorkflowRefusal.overLimit(.project).needsAPerson)
        #expect(WorkflowRefusal.overLimit(.total).needsAPerson)
        // And a setting that cannot be had: it refuses every fire until either the file
        // changes or the runtime starts offering it, and neither happens by itself.
        #expect(WorkflowRefusal.settingRefused(setting: "permission-mode", detail: "x").needsAPerson)
        #expect(!WorkflowRefusal.runInFlight.needsAPerson)
        #expect(!WorkflowRefusal.archived.needsAPerson)
        #expect(!WorkflowRefusal.missedWhileClosed.needsAPerson)
        #expect(!WorkflowRefusal.agentUnavailable.needsAPerson)
    }

    // MARK: Responding to events

    @Test func aWorkflowRespondsOnlyToWhatItNames() {
        let onFinish = workflow(triggers: [.agentFinished])
        #expect(onFinish.responds(to: .finished))
        #expect(!onFinish.responds(to: .stopped))
    }

    @Test func aBrokenWorkflowRespondsToNothing() {
        let broken = workflow(triggers: [.agentFinished], problem: .unreadable("x"))
        #expect(!broken.responds(to: .finished))
    }

    @Test func aWorkflowWatchingEveryWorkflowDoesNotWatchItself() {
        // A loop with nothing in it. The depth limit should not have to be what stops
        // something this obvious.
        let chained = Workflow(workflowID: "w", folder: URL(filePath: "/tmp/p"),
                               triggers: [.workflowCompleted(id: nil)], prompt: "go")
        #expect(!chained.respondsToCompletion(of: "w"))
        #expect(chained.respondsToCompletion(of: "other"))
    }
}
