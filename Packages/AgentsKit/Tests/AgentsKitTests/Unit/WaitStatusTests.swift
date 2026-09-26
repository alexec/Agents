import Foundation
import Testing
@testable import AgentsKitCore

/// Both kinds of waiting, said one way (042 FR-012, R4).
@Suite("Wait status")
struct WaitStatusTests {
    private let dir = URL(fileURLWithPath: "/tmp/project")
    private let since = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 25, hour: 23, minute: 30))!
    private let until = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 26, hour: 9, minute: 0))!

    private func agent() -> Agent { Agent(runtimeID: "claude", cwd: dir, state: .finished, endedReason: .endTurn) }

    @Test func aPlainAgentWaitsOnNothing() {
        #expect(WaitStatus.of(agent(), names: { _ in nil }) == nil)
    }

    @Test func anEventWaitSaysWhatSinceAndUntil() {
        var waiting = agent()
        waiting.eventWait = EventWait(patterns: [EventPattern("pull_request.merged", filters: ["number": "44"])],
                                      from: 0, deadline: until, since: since)
        let status = WaitStatus.of(waiting, names: { _ in nil })
        #expect(status?.line == "◷ Waiting for pull_request.merged #44 · since 23:30 · until 09:00")
        #expect(status?.mark == "◷ Waiting for pull_request.merged #44")
        #expect(status?.cancellable == true)
    }

    @Test func withoutADeadlineThereIsNoUntil() {
        var waiting = agent()
        waiting.eventWait = EventWait(patterns: [EventPattern("mac.wake")], from: 0, since: since)
        #expect(WaitStatus.of(waiting, names: { _ in nil })?.line == "◷ Waiting for mac.wake · since 23:30")
    }

    @Test func anEndedWaitIsNotShown() {
        var waiting = agent()
        waiting.eventWait = EventWait(patterns: [EventPattern("mac.wake")], from: 0, since: since, ending: .timedOut)
        #expect(WaitStatus.of(waiting, names: { _ in nil }) == nil)
    }

    @Test func aBlockOnAgentsAndAWaitOnThemFinishingReadTheSame() {
        let fixLogin = UUID(), docs = UUID()
        let names: (UUID) -> String? = { [fixLogin: "Fix login", docs: "Docs"][$0] }

        var blocked = agent()
        blocked.report = WorkReport(outcome: .blocked, message: "waiting", at: since,
                                    block: Block(waits: [Wait(agentID: fixLogin, nameAtReport: "Fix login")]))
        var waiting = agent()
        waiting.eventWait = EventWait(patterns: [EventPattern("agent.finished", filters: ["agent": fixLogin.uuidString])],
                                      from: 0, since: since)

        let block = WaitStatus.of(blocked, names: names)
        let wait = WaitStatus.of(waiting, names: names)
        #expect(block?.mark == "◷ Waiting for “Fix login” to finish")
        #expect(wait?.mark == block?.mark)
        #expect(block?.cancellable == false)

        var both = agent()
        both.report = WorkReport(outcome: .blocked, message: "waiting", at: since,
                                 block: Block(waits: [Wait(agentID: fixLogin, nameAtReport: "Fix login"),
                                                      Wait(agentID: docs, nameAtReport: "Docs")]))
        #expect(WaitStatus.of(both, names: names)?.mark == "◷ Waiting for “Fix login” and “Docs” to finish")
    }
}
