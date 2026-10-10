import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// `cooldown:` (#103): read from the file, said back, and what it does to a fire.
@Suite("A workflow's cooldown")
struct WorkflowCooldownTests {
    private let project = URL(filePath: "/tmp/p")

    private func file(_ cooldown: String) -> Workflow {
        WorkflowFile.parse("---\non:\n  - agent.finished\ncooldown: \(cooldown)\n---\n\nGo.\n",
                           workflowID: "w", in: project)
    }

    @Test func readsMinutesHoursDaysAndTheirSums() {
        #expect(file("15m").cooldown == TimeInterval(15 * 60))
        #expect(file("2h").cooldown == TimeInterval(2 * 3_600))
        #expect(file("1d").cooldown == 86_400)
        #expect(file("1h30m").cooldown == TimeInterval(90 * 60))
        #expect(file("15m").problem == nil)
    }

    @Test func withoutTheKeyThereIsNone() {
        let plain = WorkflowFile.parse("---\non:\n  - agent.finished\n---\n\nGo.\n", workflowID: "w", in: project)
        #expect(plain.cooldown == nil)
        #expect(plain.problem == nil)
    }

    @Test func aWrongOneIsAFileToFixWithASentence() {
        #expect(file("soon").problem
            == .unreadable("`cooldown:` must be a length of time, like 15m, 2h or 1d, not \"soon\""))
        #expect(file("15").problem
            == .unreadable("`cooldown:` must be a length of time, like 15m, 2h or 1d, not \"15\""))
        #expect(file("30s").problem
            == .unreadable("`cooldown:` must be a length of time, like 15m, 2h or 1d, not \"30s\""))
        #expect(file("0m").problem == .unreadable("`cooldown:` must be at least a minute, not \"0m\""))
        #expect(file("[15m]").problem == .unreadable("`cooldown:` must be a single value, like 15m"))
        // What can still be read of a broken file is still shown.
        #expect(file("soon").triggers == [.event(EventPattern("agent.finished"))])
    }

    @Test func itIsKnownSoNotKeptAsAnUnknownField() {
        #expect(file("15m").unknownFields["cooldown"] == nil)
    }

    @Test func isSaidInWordsAndInTheFilesOwnForm() {
        #expect(WorkflowCooldown.words(15 * 60) == "15 minutes")
        #expect(WorkflowCooldown.words(90 * 60) == "1 hour 30 minutes")
        #expect(WorkflowCooldown.fileText(90 * 60) == "1h30m")
        #expect(WorkflowCooldown.fileText(86_400) == "1d")
        #expect(file("15m").summary == "When an agent in this project ended a turn having done its work, "
                + "in a new agent, at most once every 15 minutes")
    }

    // MARK: The rule

    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func refusal(_ workflow: Workflow, isRunning: Bool = false, depth: Int = 0,
                         lastStartedAt: Date?, now: Date, byHand: Bool = false) -> WorkflowRefusal? {
        workflow.refusalIfBlocked(isRunning: isRunning, depth: depth, lastStartedAt: lastStartedAt,
                                  now: now, byHand: byHand)
    }

    @Test func aFireInsideTheCooldownIsHeldUntilItEnds() {
        let end = start.addingTimeInterval(15 * 60)
        #expect(refusal(file("15m"), lastStartedAt: start, now: start.addingTimeInterval(60))
            == .coolingDown(until: end))
    }

    @Test func aFireAfterItRuns() {
        #expect(refusal(file("15m"), lastStartedAt: start, now: start.addingTimeInterval(15 * 60)) == nil)
        #expect(refusal(file("15m"), lastStartedAt: nil, now: start) == nil)
    }

    @Test func aRunStillGoingPastTheCooldownHoldsRatherThanDrops() {
        #expect(refusal(file("15m"), isRunning: true, lastStartedAt: start, now: start.addingTimeInterval(3_600))
            == .coolingDown(until: nil))
        // Without a cooldown: queued, each to run on its own (#422).
        let plain = WorkflowFile.parse("---\non:\n  - agent.finished\n---\n\nGo.\n", workflowID: "w", in: project)
        #expect(refusal(plain, isRunning: true, lastStartedAt: start, now: start.addingTimeInterval(60)) == .queued)
    }

    @Test func runNowIgnoresTheCooldownButNotARunInFlight() {
        #expect(refusal(file("15m"), lastStartedAt: start, now: start.addingTimeInterval(60), byHand: true) == nil)
        #expect(refusal(file("15m"), isRunning: true, lastStartedAt: start, now: start.addingTimeInterval(60),
                        byHand: true) == .runInFlight)
    }

    @Test func aChainTooDeepIsRefusedNotHeld() {
        #expect(refusal(file("15m"), depth: Workflow.chainDepthLimit + 1, lastStartedAt: start,
                        now: start.addingTimeInterval(60)) == .chainTooDeep(depth: Workflow.chainDepthLimit))
    }

    @Test func heldTriggersCountUpOnOneLineThatSaysWaiting() {
        let end = start.addingTimeInterval(15 * 60)
        let first = WorkflowOutcome.refused(.coolingDown(until: end), at: start, repeats: 1)
        let second = WorkflowOutcome.refused(.coolingDown(until: end), at: start.addingTimeInterval(60), repeats: 1)
            .following(first)
        guard case .refused(_, _, 2) = second else { Issue.record("expected two held"); return }
        let time = end.formatted(date: .omitted, time: .shortened)
        #expect(first.summary == "Waiting — it is cooling down until \(time), and runs once then")
        #expect(second.summary == "Waiting — 2 triggers held into one run, as it is cooling down until \(time), and runs once then")
        #expect(WorkflowRefusal.coolingDown(until: end).needsAPerson == false)
    }
}
