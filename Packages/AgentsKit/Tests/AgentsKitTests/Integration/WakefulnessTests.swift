import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// Whether a real agent, driven through a real `DaemonCore`, takes and lets go of the
/// Mac's idle sleep at the right moments.
///
/// The agent lifecycle is **not** faked here — only the machine is. `FakePowerSource`
/// and `RecordingWakefulness` stand in for IOKit and the assertion, and everything
/// between a prompt and a finished turn is the daemon doing what it really does. The
/// thing under test is the derivation, not a mock of it.
@Suite("Holding the Mac awake", .timeLimit(.minutes(1)))
struct WakefulnessTests {
    private func temporary() throws -> (StoreLocations, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsWakeTests-\(UUID().uuidString)", isDirectory: true)
        let work = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        return (StoreLocations(root: root), work)
    }

    private func core(_ launcher: FakeLauncher,
                      locations: StoreLocations,
                      power: FakePowerSource,
                      wakefulness: RecordingWakefulness) throws -> DaemonCore {
        DaemonCore(store: try AgentStore(locations: locations),
                   locations: locations,
                   discovery: .findsEverything,
                   launcher: launcher,
                   power: power,
                   wakefulness: wakefulness)
    }

    /// A runtime whose turn takes long enough to observe it happening.
    private func working(for delay: Duration = .milliseconds(600)) -> FakeLauncher {
        var script = FakeACPAgent.Script()
        script.turnDelay = delay
        return FakeLauncher(script: script)
    }

    /// A runtime that asks permission mid-turn and waits on the answer.
    private func asking() -> FakeLauncher {
        var script = FakeACPAgent.Script()
        script.permission = ["toolCall": ["title": "Write hello.txt"],
                             "options": [["optionId": "allow", "name": "Allow", "kind": "allow_once"],
                                         ["optionId": "no", "name": "Reject", "kind": "reject_once"]]]
        return FakeLauncher(script: script)
    }

    // MARK: US1 — a turn in flight holds the Mac

    @Test("A turn in flight holds the Mac awake, and ending it lets go")
    func aTurnHoldsAndReleases() async throws {
        let (locations, work) = try temporary()
        let power = FakePowerSource.mains
        let wake = RecordingWakefulness()
        let core = try core(working(), locations: locations, power: power, wakefulness: wake)

        let id = try await core.start(.init(runtimeID: "copilot", cwd: work, prompt: "do a thing"))

        await eventually("the Mac is being held awake") { wake.isHolding }
        #expect(wake.holds == 1)

        await eventually("the turn ended") { await core.agent(id)?.state == .finished }
        await eventually("the Mac was given back") { !wake.isHolding }

        // Once each, not once per streamed token. The early return in
        // `reviseWakefulness` is what makes this true, and it has its own test below.
        #expect(wake.holds == 1)
        #expect(wake.releases == 1)
    }

    @Test("The reason names us and says what for, because pmset shows it verbatim")
    func theReasonIsForAPersonAtATerminal() async throws {
        let (locations, work) = try temporary()
        let power = FakePowerSource.mains
        let wake = RecordingWakefulness()
        let core = try core(working(), locations: locations, power: power, wakefulness: wake)

        _ = try await core.start(.init(runtimeID: "copilot", cwd: work, prompt: "do a thing"))
        await eventually("the Mac is being held awake") { wake.isHolding }

        // No count in it, on purpose. The Phase 3 walk found that a count here goes
        // stale: `reviseWakefulness` acts only when the verdict moves, so three real
        // agents running showed "1 agent". The count lives in `WakeState` instead,
        // where it can be re-sent freely.
        #expect(wake.lastReason == "Agents: a turn is in flight")
        #expect(wake.lastReason?.contains("Agents") == true)
    }

    @Test("Three agents at once cause exactly one hold, released only when the last ends")
    func threeAgentsOneHold() async throws {
        let (locations, work) = try temporary()
        let power = FakePowerSource.mains
        let wake = RecordingWakefulness()
        let core = try core(working(for: .milliseconds(900)),
                            locations: locations, power: power, wakefulness: wake)

        var started: [UUID] = []
        for n in 1...3 {
            started.append(try await core.start(
                .init(runtimeID: "copilot", cwd: work, prompt: "job \(n)")))
        }
        // Bound to a `let` before the closure below: `eventually` takes a `@Sendable`
        // body, and a captured `var` is not allowed to cross into it.
        let ids = started

        await eventually("the Mac is being held awake") { wake.isHolding }
        #expect(wake.holds == 1)

        await eventually("every turn ended") {
            for id in ids where await core.agent(id)?.state != .finished { return false }
            return true
        }
        await eventually("the Mac was given back") { !wake.isHolding }

        // One hold and one release across the whole overlapping span (FR-006, US1-3).
        // Three holds would mean one assertion per agent; a release in the middle would
        // mean the first agent to finish handed back a Mac two others were still using.
        #expect(wake.holds == 1)
        #expect(wake.releases == 1)
    }

    @Test("A streamed token that changes nothing does not hold a second time")
    func repeatedChangesDoNotReHold() async throws {
        let (locations, work) = try temporary()
        let power = FakePowerSource.mains
        let wake = RecordingWakefulness()
        let core = try core(working(for: .seconds(5)),
                            locations: locations, power: power, wakefulness: wake)

        let id = try await core.start(.init(runtimeID: "copilot", cwd: work, prompt: "a long one"))
        await eventually("the Mac is being held awake") { wake.isHolding }

        // `changed(_:)` is what a streamed token reaches, and it is where
        // `reviseWakefulness` is called from. Re-entering it with the agent in the same
        // state is precisely the flood case, so drive it directly.
        guard let agent = await core.agent(id) else {
            Issue.record("the agent vanished"); return
        }
        for _ in 0..<5 { await core.changed(agent) }

        // Still exactly one. Without the early return this would be six, and five
        // `beginActivity` tokens would have been dropped on the floor — an assertion
        // leaked for the life of the process.
        #expect(wake.holds == 1)
        #expect(wake.releases == 0)

        try await core.stop(id)
    }

    // MARK: US1 — the states that do not count

    @Test("An agent waiting on a person does not hold the Mac")
    func waitingOnAPersonDoesNotHold() async throws {
        let (locations, work) = try temporary()
        let power = FakePowerSource.mains
        let wake = RecordingWakefulness()
        let core = try core(asking(), locations: locations, power: power, wakefulness: wake)

        let id = try await core.start(.init(runtimeID: "copilot", cwd: work, prompt: "write it"))

        await eventually("the agent is blocked on its question") {
            await core.agent(id)?.state == .waitingOnUser
        }
        await eventually("the Mac was given back while it waits") { !wake.isHolding }

        // The test this feature exists for. `isHoldingAgents` answers **true** for this
        // very agent, because exiting under an unanswered question would abandon it —
        // right question, wrong answer for us. A Mac held awake all night waiting for
        // somebody to come back and click Allow is the one abuse FR-003 forbids.
        #expect(await core.hasWorkInFlight == false)

        // Genuinely let go, not merely never taken: the turn was running before the
        // question was asked, so there was a hold to give back.
        #expect(wake.holds == 1)
        #expect(wake.releases == 1)
    }

    @Test("Answering the question puts the hold back, because the turn resumes")
    func answeringResumesTheHold() async throws {
        let (locations, work) = try temporary()
        let power = FakePowerSource.mains
        let wake = RecordingWakefulness()
        let core = try core(asking(), locations: locations, power: power, wakefulness: wake)

        let id = try await core.start(.init(runtimeID: "copilot", cwd: work, prompt: "write it"))
        await eventually("the agent is blocked on its question") {
            await core.agent(id)?.state == .waitingOnUser
        }
        await eventually("the Mac was given back while it waits") { !wake.isHolding }

        let question = try #require(await core.pendingPermissionRequests().first)
        try await core.answerPermission(.init(permissionID: question.id, optionID: "allow"))

        // Back to running, so back to holding. Two holds now, which is correct and is
        // the price of the narrow rule: a question in the middle of a long turn bounces
        // the assertion. Cheap, and the alternative is holding through an unanswered
        // question all night.
        await eventually("the turn resumed and the Mac is held again") { wake.holds == 2 }
    }

    @Test("Stopping an agent by hand gives the Mac back at once")
    func stoppingReleases() async throws {
        let (locations, work) = try temporary()
        let power = FakePowerSource.mains
        let wake = RecordingWakefulness()
        let core = try core(working(for: .seconds(5)),
                            locations: locations, power: power, wakefulness: wake)

        let id = try await core.start(.init(runtimeID: "copilot", cwd: work, prompt: "a long one"))
        await eventually("the Mac is being held awake") { wake.isHolding }

        try await core.stop(id)

        // At the moment it is stopped, not at the end of a turn it never reached.
        await eventually("the Mac was given back") { !wake.isHolding }
        #expect(await core.agent(id)?.state == .stopped)
    }

    // MARK: What counts as work in flight

    @Test("Only starting and running count as work in flight")
    func onlyTwoStatesCount() async throws {
        // A fresh core per state, so each is asked about exactly one agent. Populated
        // through `changed(_:)`, which is the real path an agent's record takes — no
        // test-only door into the actor's table.
        for state in AgentState.allCases {
            let (locations, work) = try temporary()
            let core = try core(working(), locations: locations,
                                power: FakePowerSource.mains,
                                wakefulness: RecordingWakefulness())
            // A stopped or archived agent must carry a reason, or the record's own
            // invariants refuse it on the way to disk.
            let needsReason = state == .stopped || state == .archived
            let agent = Agent(runtimeID: "copilot", cwd: work, state: state,
                              endedReason: needsReason ? .cancelled : nil,
                              archivedReason: state == .archived ? .byUser : nil)
            await core.changed(agent)

            // Asking the real property rather than restating the rule. This guards the
            // line that is one word away from either of its two neighbours:
            // `AgentState.hasTurnInFlight` includes `waitingOnUser`, and so does
            // `isHoldingAgents`. This one must not.
            let expected = state == .starting || state == .running
            #expect(await core.hasWorkInFlight == expected,
                    "\(state) is on the wrong side of the rule")
            #expect(await core.agentsInFlight == (expected ? 1 : 0))
        }
    }

    // MARK: US3 — the battery floor
    //
    // The whole truth table lives in `WakeVerdictTests` with no daemon in sight. What
    // these add is the half a pure function cannot cover: that the 15-second tick is
    // wired to notice the machine moving under a turn that is still running, and that
    // a laptop is let go of rather than held to empty (FR-010, FR-011).

    @Test("Crossing the floor mid-turn gives the Mac back, though the turn runs on")
    func crossingTheFloorReleasesMidTurn() async throws {
        let (locations, work) = try temporary()
        let power = FakePowerSource()
        power.onBattery(Wake.batteryFloorPercent + 40)
        let wake = RecordingWakefulness()
        let core = try core(working(for: .seconds(5)),
                            locations: locations, power: power, wakefulness: wake)

        let id = try await core.start(.init(runtimeID: "copilot", cwd: work, prompt: "a long one"))
        await eventually("held while the charge is comfortable") { wake.isHolding }

        // The sofa case: unplugged, and the battery runs down under a turn that has not
        // finished. Nothing about the *agent* changes, so `changed(_:)` will not notice
        // — only the tick reads the power.
        power.onBattery(Wake.batteryFloorPercent - 1)
        // Still held: the machine moved but nothing has looked yet. This line is what
        // makes the next one mean something — without it the test would pass just as
        // happily if the hold had been dropped for some entirely different reason.
        #expect(wake.isHolding)

        await core.tickWorkflows(now: Date())

        #expect(!wake.isHolding)
        #expect(wake.releases == 1)
        // And the turn really is still going. The point of FR-010 is that the work is
        // abandoned to the Mac's own idle timer rather than the battery being spent to
        // the end — not that the work stopped.
        #expect(await core.agent(id)?.state == .running)

        try await core.stop(id)
    }

    @Test("At the floor exactly is already too low")
    func atTheFloorReleases() async throws {
        let (locations, work) = try temporary()
        let power = FakePowerSource()
        power.onBattery(Wake.batteryFloorPercent + 1)
        let wake = RecordingWakefulness()
        let core = try core(working(for: .seconds(5)),
                            locations: locations, power: power, wakefulness: wake)

        let id = try await core.start(.init(runtimeID: "copilot", cwd: work, prompt: "a long one"))
        await eventually("held one percent above the floor") { wake.isHolding }

        // FR-010 says "reaches or falls below", so the floor itself is too low. `>` and
        // `>=` both read plausibly in the source and only one matches the requirement.
        power.onBattery(Wake.batteryFloorPercent)
        await core.tickWorkflows(now: Date())
        #expect(!wake.isHolding)

        try await core.stop(id)
    }

    @Test("Plugging back in takes the hold up again, without waiting for the next turn")
    func plugginqBackInReHolds() async throws {
        let (locations, work) = try temporary()
        let power = FakePowerSource()
        power.onBattery(Wake.batteryFloorPercent - 5)
        let wake = RecordingWakefulness()
        let core = try core(working(for: .seconds(5)),
                            locations: locations, power: power, wakefulness: wake)

        let id = try await core.start(.init(runtimeID: "copilot", cwd: work, prompt: "a long one"))
        await eventually("the turn is running") { await core.agent(id)?.state == .running }
        // Started below the floor, so it was never held at all.
        #expect(!wake.isHolding)
        #expect(wake.holds == 0)

        // Plugged in, with the same turn still going. FR-011: the hold comes back on
        // the tick, not on the next agent to do something.
        power.onMains(Wake.batteryFloorPercent - 5)
        // Not yet: plugging in is invisible until something reads the power, and the
        // agent has not moved. If this were already holding, the tick below would be
        // proving nothing.
        #expect(!wake.isHolding)

        await core.tickWorkflows(now: Date())

        #expect(wake.isHolding)
        #expect(wake.holds == 1)
        #expect(await core.agent(id)?.state == .running)

        try await core.stop(id)
    }

    @Test("On mains the charge is not our business, even at 5%")
    func mainsHoldsAtAnyCharge() async throws {
        let (locations, work) = try temporary()
        let power = FakePowerSource()
        power.onMains(5)
        let wake = RecordingWakefulness()
        let core = try core(working(), locations: locations, power: power, wakefulness: wake)

        _ = try await core.start(.init(runtimeID: "copilot", cwd: work, prompt: "do a thing"))
        // FR-009. A charge below the floor means nothing while the wall is supplying it.
        await eventually("held on mains at 5%") { wake.isHolding }
    }

    @Test("A Mac with no battery is held whatever the tick says")
    func desktopHolds() async throws {
        let (locations, work) = try temporary()
        // A desktop: no battery at all, which is not the same fact as a flat one.
        let power = FakePowerSource(.init(batteryPercent: nil, isOnMains: true))
        let wake = RecordingWakefulness()
        let core = try core(working(for: .seconds(5)),
                            locations: locations, power: power, wakefulness: wake)

        let id = try await core.start(.init(runtimeID: "copilot", cwd: work, prompt: "a long one"))
        await eventually("held on a machine with no battery") { wake.isHolding }

        // FR-012: ticking must not talk a desktop out of it. If `batteryPercent` were a
        // non-optional 0 this would read as flat and release here.
        await core.tickWorkflows(now: Date())
        #expect(wake.isHolding)
        #expect(wake.releases == 0)

        try await core.stop(id)
    }

    @Test("The tick is a backstop, never the thing that ends a hold when a turn ends")
    func theTickIsOnlyABackstop() async throws {
        let (locations, work) = try temporary()
        let power = FakePowerSource.mains
        let wake = RecordingWakefulness()
        let core = try core(working(), locations: locations, power: power, wakefulness: wake)

        let id = try await core.start(.init(runtimeID: "copilot", cwd: work, prompt: "do a thing"))
        await eventually("the turn ended") { await core.agent(id)?.state == .finished }

        // T033, as an assertion rather than a reading. The release must already have
        // happened, from `changed(_:)`, without any tick at all — if this needs a tick
        // then FR-004's five seconds is being met by a fifteen-second timer, which is
        // to say not met.
        #expect(!wake.isHolding)
        #expect(wake.releases == 1)
    }
}
