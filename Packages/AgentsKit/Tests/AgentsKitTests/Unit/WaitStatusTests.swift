import Foundation
import Testing
@testable import AgentsKitCore

/// Both kinds of waiting, said one way (042 FR-012, R4).
@Suite("Wait status")
struct WaitStatusTests {
    private let dir = URL(fileURLWithPath: "/tmp/folder")
    private let since = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 25, hour: 23, minute: 30))!
    private let until = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 26, hour: 9, minute: 0))!

    private func agent() -> Agent { Agent(runtimeID: "claude", cwd: dir, state: .finished, endedReason: .endTurn) }

    @Test func aPlainAgentWaitsOnNothing() {
        #expect(WaitStatus.of(agent(), names: { _ in nil }) == nil)
    }

    @Test func anEventWaitSaysWhatSinceAndUntil() {
        var waiting = agent()
        waiting.eventWait = EventWait(patterns: [EventPattern("branch.moved", filters: ["branch": "main"])],
                                      from: 0, deadline: until, since: since)
        let status = WaitStatus.of(waiting, names: { _ in nil })
        #expect(status?.line == "◷ Waiting for branch.moved branch main · since 23:30 · until 09:00")
        #expect(status?.mark == "◷ Waiting for branch.moved branch main")
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
        blocked.report = WorkReport(outcome: .waiting, message: "waiting", at: since,
                                    block: Block(waits: [Wait(agentID: fixLogin, nameAtReport: "Fix login")]))
        var waiting = agent()
        waiting.eventWait = EventWait(patterns: [EventPattern("agent.finished", filters: ["agent": DetailFilter(fixLogin.uuidString)])],
                                      from: 0, since: since)

        let block = WaitStatus.of(blocked, names: names)
        let wait = WaitStatus.of(waiting, names: names)
        #expect(block?.mark == "◷ Waiting for “Fix login” to finish")
        #expect(wait?.mark == block?.mark)
        #expect(block?.cancellable == false)

        var both = agent()
        both.report = WorkReport(outcome: .waiting, message: "waiting", at: since,
                                 block: Block(waits: [Wait(agentID: fixLogin, nameAtReport: "Fix login"),
                                                      Wait(agentID: docs, nameAtReport: "Docs")]))
        #expect(WaitStatus.of(both, names: names)?.mark == "◷ Waiting for “Fix login” and “Docs” to finish")
    }

    @Test func aRowSaysTheFirstThingAndHowManyMore() {
        #expect(WaitStatus.rowLine([]) == nil)
        #expect(WaitStatus.rowLine(["“Fix login”"]) == "◷ Waiting for “Fix login”")
        #expect(WaitStatus.rowLine(["“Fix login”", "“Docs”", "build"]) == "◷ Waiting for “Fix login” (+2)")
    }

    @Test func aWaitOnEventsIsOneThingAPattern() {
        let fixLogin = UUID()
        let patterns = [EventPattern("agent.finished", filters: ["agent": DetailFilter(fixLogin.uuidString)]),
                        EventPattern("mac.wake")]
        #expect(WaitStatus.things(patterns, names: { $0 == fixLogin ? "Fix login" : nil }) == ["“Fix login”", "mac.wake"])
    }

    /// An agent beside another event is still said by its name, not its id (#3236).
    @Test func anAgentBesideAnotherEventIsSaidByItsName() {
        let tidy = UUID()
        var waiting = agent()
        waiting.eventWait = EventWait(patterns: [EventPattern("agent.finished", filters: ["agent": DetailFilter(tidy.uuidString)]),
                                                 EventPattern("ci.finished")],
                                      from: 0, deadline: until, since: since)
        let status = WaitStatus.of(waiting, names: { $0 == tidy ? "Tidy tests" : nil })
        #expect(status?.line == "◷ Waiting for “Tidy tests” to finish or ci.finished · since 23:30 · until 09:00")
    }

    /// A place in a lease's line is a wait on its own grant (#2361), said as the line says it,
    /// and left out of the lease row so it is said once.
    @Test func aPlaceInLineIsSaidAsTheLineSaysIt() throws {
        let fixLogin = UUID()
        var waiting = agent()
        let wait = EventWait(patterns: [EventPattern("lease.granted", filters: [
            "agent": DetailFilter(waiting.id.uuidString), "resource": DetailFilter("build")])], from: 0, deadline: until, since: since)
        waiting.eventWait = wait
        #expect(wait.lineResource == ResourceName("build"))
        // Continue on it names the lease, and says the agent is out of the line (#3151).
        #expect(EventWait.lineCarryOnLabel(ResourceName("build")!) == "Carry on without build")
        #expect(EventWait.lineCarryOnPrompt(ResourceName("build")!) == "I've taken you out of the line for build. Carry on without it.")
        #expect(WaitStatus.of(waiting, names: { _ in nil })?.line == "◷ Waiting for your turn with build")

        let build = ResourceName("build")!
        let snapshot = DaemonAPI.LeaseSnapshot(resources: [
            .init(name: build, kind: .named, displayName: "Build",
                  lease: Lease(resource: build, displayName: "Build", holder: fixLogin, grantedAt: since, expiresAt: until),
                  line: [.init(agentID: UUID(), askedAt: since, isCallOpen: true),
                         .init(agentID: waiting.id, askedAt: since, isCallOpen: true)]),
        ], at: since)
        let lease = try #require(LeaseStatus.of(waiting.id, in: snapshot, titles: [fixLogin: "Fix login"]))
        let status = WaitStatus.of(waiting, names: { _ in nil }, lease: lease)
        #expect(status?.line == "◷ Waiting for Build · held by “Fix login” until 09:00 · 2nd in line")
        #expect(status?.mark == "◷ Waiting for Build · 2nd in line")
        #expect(status?.cancellable == true)
        #expect(WaitStatus.things(wait, names: { _ in nil }, lease: lease) == ["Build"])
        #expect(lease.without(wait) == nil)
        #expect(lease.without(nil) == lease)
    }

    /// The wait card names a session by its title and an event by its meaning (#2747).
    @Test func theWaitCardSaysItsEventsInWords() throws {
        let fixLogin = UUID(), docs = UUID()
        let names: (UUID) -> String? = { [fixLogin: "Fix login", docs: "Docs"][$0] }
        let wait = EventWait(patterns: [
            EventPattern("agent.finished", filters: ["agent": DetailFilter(fixLogin.uuidString)]),
            EventPattern("agent.finished", filters: ["agent": DetailFilter(docs.uuidString)]),
            EventPattern("agent.failed", filters: ["agent": DetailFilter(docs.uuidString)]),
            EventPattern("agent.stopped", filters: ["agent": DetailFilter(docs.uuidString)]),
            EventPattern("mac.wake"),
            EventPattern("checks.failed"),
            EventPattern("pr.merged"),
        ], from: 0, since: since, serverEvents: [
            WaitServerEvent(trigger: MCPEventTrigger(event: "checks.failed", arguments: ["pr": .int(123)]), servers: ["github"]),
            WaitServerEvent(trigger: MCPEventTrigger(event: "pr.merged", arguments: ["pr": .int(123)]), servers: ["github"]),
        ])
        let lines = WaitEventLine.lines(for: wait, names: names)
        try #require(lines.count == 4)
        #expect(lines.map { "\($0.source) · \($0.words)" + ($0.arguments.isEmpty ? "" : " (\($0.arguments.joined(separator: ", ")))") } == [
            "Agents · “Fix login” and “Docs” to finish",
            "Agents · An agent in this folder ended in an error or an agent in this folder was stopped before finishing (agent “Docs”)",
            "This Mac · This Mac woke up",
            "GitHub · Checks failed or PR merged (pr 123)",
        ])
        #expect(lines[0].events == ["agent.finished"]) // index-ok: required four above
        #expect(lines[3].events == ["checks.failed", "pr.merged"]) // index-ok: required four above
    }

    /// The card's event line links to the PR its arguments name (#3077), from the group's
    /// own server event rather than guessed from its words.
    @Test func theWaitCardLinksToWhatItsArgumentsName() throws {
        let wait = EventWait(patterns: [EventPattern("pr.merged"), EventPattern("checks.failed")], from: 0, since: since,
                             serverEvents: [
            WaitServerEvent(trigger: MCPEventTrigger(event: "pr.merged",
                                                      arguments: ["repo": .string("alexec/Agents"), "pr": .int(123)]), servers: ["github"]),
            WaitServerEvent(trigger: MCPEventTrigger(event: "checks.failed",
                                                      arguments: ["repo": .string("alexec/Agents"), "pr": .int(123)]), servers: ["github"]),
        ])
        let lines = WaitEventLine.lines(for: wait, names: { _ in nil })
        try #require(lines.count == 1)
        #expect(lines[0].url == URL(string: "https://github.com/alexec/Agents/pull/123"))
    }

    @Test func theWaitCardHasNoLinkWithoutAPROrAnIssue() throws {
        let wait = EventWait(patterns: [EventPattern("mac.wake")], from: 0, since: since)
        let lines = WaitEventLine.lines(for: wait, names: { _ in nil })
        try #require(lines.count == 1)
        #expect(lines[0].url == nil)
    }

    @Test func aSessionTheWindowDoesNotKnowIsItsID() {
        let gone = UUID()
        let wait = EventWait(patterns: [EventPattern("agent.finished", filters: ["agent": DetailFilter(gone.uuidString)])],
                             from: 0, since: since)
        #expect(WaitEventLine.lines(for: wait, names: { _ in nil }).first?.words == "“\(gone.uuidString)” to finish")
    }
}
