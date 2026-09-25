import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// A wait, as a value on the agent's record (042 R3, FR-007, FR-014).
@Suite("An event wait")
struct EventWaitModelTests {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private let dir = URL(fileURLWithPath: "/tmp/project")

    private func event(_ name: String, position: EventPosition, _ details: [String: String] = [:]) -> Event {
        Event(position: position, name: name, at: t0, scope: .project(folder: dir), sentence: "", details: details)
    }

    @Test func itMatchesOnlyAfterItsPosition() {
        let wait = EventWait(patterns: [EventPattern("custom.ping")], from: 5, since: t0)
        #expect(!wait.matches(event("custom.ping", position: 5)))
        #expect(wait.matches(event("custom.ping", position: 6)))
        #expect(!wait.matches(event("custom.pong", position: 6)))
    }

    @Test func anyOfItsPatternsWillDo() {
        let wait = EventWait(patterns: [EventPattern("pull_request.checks_passed", filters: ["number": "41"]),
                                        EventPattern("pull_request.checks_failed", filters: ["number": "41"])],
                             from: 0, since: t0)
        #expect(wait.matches(event("pull_request.checks_failed", position: 1, ["number": "41"])))
        #expect(!wait.matches(event("pull_request.checks_failed", position: 1, ["number": "40"])))
        #expect(wait.label == "pull_request.checks_passed #41 or pull_request.checks_failed #41")
    }

    @Test func itIsDueOnlyWhileOpenAndPastItsDeadline() {
        var wait = EventWait(patterns: [EventPattern("mac.wake")], from: 0,
                             deadline: t0.addingTimeInterval(60), since: t0)
        #expect(!wait.isDue(now: t0))
        #expect(wait.isDue(now: t0.addingTimeInterval(60)))
        wait.ending = .timedOut
        #expect(!wait.isDue(now: t0.addingTimeInterval(60)))
        #expect(!wait.isOpen)
    }

    @Test func itTravelsOnTheAgentsRecordAndAnOldRecordHasNone() throws {
        var agent = Agent(runtimeID: "claude", cwd: dir, state: .finished, endedReason: .endTurn)
        #expect(agent.eventWait == nil)
        agent.eventWait = EventWait(patterns: [EventPattern("pull_request.merged", filters: ["number": "44"])],
                                    from: 12, deadline: t0.addingTimeInterval(3600), since: t0,
                                    ending: .matched(position: 13, extraMatches: 1), resumePromptID: UUID())
        let back = try StoreCoding.decoder.decode(Agent.self, from: StoreCoding.encoder.encode(agent))
        #expect(back.eventWait == agent.eventWait)

        // Written by a version that had no waits: no key, and it reads as none.
        agent.eventWait = nil
        let plain = try StoreCoding.encoder.encode(agent)
        #expect(!String(decoding: plain, as: UTF8.self).contains("eventWait"))
    }
}
