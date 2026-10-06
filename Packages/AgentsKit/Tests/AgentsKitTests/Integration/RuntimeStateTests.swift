import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// Each runtime's state, with no pool at all (065, US4): what failed or ran out is marked
/// out, checked every four hours, and brought back by a check, a turn that works, or the
/// person. It is shown, never enforced: a prompt to an out runtime is sent as usual.
@Suite("Every runtime's state, without a pool", .timeLimit(.minutes(1)))
struct RuntimeStateTests {
    private func core(clock: TestClock = TestClock(), launcher: FakeLauncher = FakeLauncher()) throws
        -> (DaemonCore, URL, StoreLocations) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("RuntimeState-\(UUID().uuidString)", isDirectory: true)
        let work = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let locations = StoreLocations(root: root)
        let core = DaemonCore(store: try AgentStore(locations: locations), locations: locations,
                              discovery: .findsEverything, launcher: launcher, now: { clock.now })
        return (core, work, locations)
    }

    private func state(_ core: DaemonCore, _ key: String = "claude:sign-in") async -> AllowanceState? {
        await core.allowanceStates().first { $0.credentialKey == key }
    }

    private func claudeOut(at: Date) -> AllowanceState {
        var state = AllowanceState(credentialKey: "claude:sign-in", entryID: UUID(), since: at)
        state.markOut(.allowanceSpent, until: nil, payment: .allowance(label: nil), now: at, from: .typedFailure)
        return state
    }

    private var answersOK: FakeACPAgent.Script {
        var script = FakeACPAgent.Script()
        script.updates = [["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": "OK"]]]
        return script
    }

    @Test func aRuntimeThatFailsIsOutWithNoPool() async throws {
        var fails = FakeACPAgent.Script()
        fails.promptError = JSONRPCError(code: -32603, message: "Internal error")
        let (core, work, _) = try core(launcher: FakeLauncher(script: fails))
        let id = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "go"))
        await eventually("the turn ended") { await core.agent(id)?.state.hasTurnInFlight == false }
        await eventually("claude is out") { await state(core)?.isOut == true }
        guard case .out(nil, _?, .runtimeFailed) = await state(core)?.status else {
            Issue.record("\(String(describing: await state(core)?.status))"); return
        }
        #expect(await core.eventLog.events.contains { $0.name == "cost.allowance_out" })
    }

    @Test func aDueCheckRunsWithNoPoolAndBringsItBack() async throws {
        let clock = TestClock()
        let launcher = FakeLauncher(script: answersOK)
        let (core, _, _) = try core(clock: clock, launcher: launcher)
        await core.setAllowanceState(claudeOut(at: clock.now))

        clock.advance(by: AllowanceState.retryWithoutATime + 1)
        await core.tickWorkflows(now: clock.now)
        await eventually("the check passed", within: .seconds(30)) { await state(core)?.status == .available }
        #expect(launcher.launchCount == 1)
        #expect(await core.eventLog.events.contains { $0.name == "cost.allowance_back" && $0.details["how"] == "check" })
    }

    // MARK: Out since, and the freshness stamp beside it (#334)

    /// A check's result is dropped when the out was marked again while it ran, even
    /// though `since` did not move: `changedAt` did.
    @Test func aCheckIsDroppedWhenTheOutWasMarkedAgainWhileItRan() async throws {
        let clock = TestClock()
        let gate = TurnGate()
        var script = answersOK
        script.handshakeGate = gate
        let (core, _, _) = try core(clock: clock, launcher: FakeLauncher(script: script))
        let wentOut = clock.now
        await core.setAllowanceState(claudeOut(at: wentOut))

        clock.advance(by: AllowanceState.retryWithoutATime + 1)
        await core.tickWorkflows(now: clock.now)
        await eventually("the check is under way") { gate.turnsArrived >= 1 }
        var again = try #require(await state(core))
        again.markOut(.allowanceSpent, until: nil, payment: .allowance(label: nil), now: clock.now, from: .typedFailure)
        // The same status as the check began with: only the stamp says it moved.
        again.status = try #require(await state(core)).status
        await core.setAllowanceState(again)
        gate.open()
        await eventually("the check ended", within: .seconds(30)) { await core.allowanceChecks.isEmpty }
        let kept = try #require(await state(core))
        #expect(kept.isOut)
        #expect(kept.since == wentOut)
    }

    /// The first check counts from the latest word that it is out, so a stale retry
    /// time is moved to four hours after a re-mark, not after it first went out.
    @Test func theFirstCheckCountsFromTheLatestWord() async throws {
        let clock = TestClock()
        let launcher = FakeLauncher(script: answersOK)
        let (core, _, _) = try core(clock: clock, launcher: launcher)
        let wentOut = clock.now
        let remarked = wentOut.addingTimeInterval(3 * 3600)
        var out = claudeOut(at: wentOut)
        out.markOut(.allowanceSpent, until: nil, payment: .allowance(label: nil), now: remarked, from: .typedFailure)
        // A retry time older than the re-mark, as a host from before it would carry.
        out.status = .out(until: nil, retryAfter: wentOut.addingTimeInterval(AllowanceState.retryWithoutATime),
                          why: .allowanceSpent)
        await core.setAllowanceState(out)

        clock.advance(by: AllowanceState.retryWithoutATime + 1)
        await core.checkDueAllowances(now: clock.now)
        let kept = try #require(await state(core))
        guard case .out(nil, let retry?, .allowanceSpent) = kept.status else { Issue.record("\(kept.status)"); return }
        #expect(retry == remarked.addingTimeInterval(AllowanceState.retryWithoutATime))
        #expect(kept.since == wentOut)
        #expect(launcher.launchCount == 0, "not due yet")
    }

    /// A late plan window writes its reset time while the latest word is fresh, even on
    /// an out that began hours ago.
    @Test func aLateResetTimeIsTakenWhileTheLatestWordIsFresh() async throws {
        let clock = TestClock()
        let (core, work, _) = try core(clock: clock, launcher: FakeLauncher(script: answersOK))
        let id = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "go"))
        await eventually("the turn worked") { await core.agent(id)?.endedReason == .endTurn }
        let wentOut = clock.now.addingTimeInterval(-3 * 3600)
        var out = claudeOut(at: wentOut)
        out.markOut(.allowanceSpent, until: nil, payment: .allowance(label: nil), now: clock.now, from: .typedFailure)
        await core.setAllowanceState(out)

        let back = clock.now.addingTimeInterval(3600)
        await core.notePlanWindow(RateLimitInfo(status: "rejected", resetsAt: back, rateLimitType: "five_hour"), agentID: id)
        let kept = try #require(await state(core))
        #expect(kept.knownReturn == back)
        #expect(kept.since == wentOut)

        // The latest word two minutes old: not late any more, so nothing is written.
        var stale = claudeOut(at: wentOut)
        stale.markOut(.allowanceSpent, until: nil, payment: .allowance(label: nil), now: clock.now, from: .typedFailure)
        await core.setAllowanceState(stale)
        clock.advance(by: 120)
        await core.notePlanWindow(RateLimitInfo(status: "rejected", resetsAt: back, rateLimitType: "five_hour"), agentID: id)
        #expect(try #require(await state(core)).knownReturn == nil)
    }

    @Test func aTurnThatWorksBringsItBack() async throws {
        let (core, work, _) = try core()
        await core.setAllowanceState(claudeOut(at: Date()))
        let id = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "go"))
        await eventually("the turn worked") { await core.agent(id)?.endedReason == .endTurn }
        await eventually("claude is back") { await state(core)?.isOut == false }
    }

    @Test func markAvailableIsByCredentialWithNoPool() async throws {
        let (core, _, _) = try core()
        await core.setAllowanceState(claudeOut(at: Date()))
        let rows = await core.markRuntimeAvailable(credentialKey: "claude:sign-in")
        #expect(await state(core)?.isOut == false)
        #expect(rows.rows.first { $0.credentialKey == "claude:sign-in" }?.state.isOut == false)
        #expect(await core.eventLog.events.contains { $0.name == "cost.allowance_back" && $0.details["how"] == "person" })
    }

    @Test func aRuntimeOutBeforeARestartIsStillOutAfterIt() async throws {
        let (core, _, locations) = try core()
        // Whole seconds: the file keeps dates to the second.
        let before = claudeOut(at: Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down)))
        await core.setAllowanceState(before)
        let restarted = DaemonCore(store: try AgentStore(locations: locations), locations: locations,
                                   discovery: .findsEverything, launcher: FakeLauncher())
        let kept = try #require(await restarted.allowanceStates().first { $0.credentialKey == "claude:sign-in" })
        #expect(kept.isOut)
        #expect(kept.status == before.status)
    }

    @Test func aPromptToAnOutRuntimeIsSentAsUsual() async throws {
        let launcher = FakeLauncher()
        let (core, work, _) = try core(launcher: launcher)
        await core.setAllowanceState(claudeOut(at: Date()))
        let id = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "go"))
        await eventually("the turn worked") { await core.agent(id)?.endedReason == .endTurn }
        #expect(launcher.launches.first?.runtime == "claude")
    }

    @Test func everyLocatedRuntimeHasARowAvailableUntilToldOtherwise() async throws {
        let (core, _, _) = try core()
        await core.setAllowanceState(claudeOut(at: Date()))
        let rows = await core.runtimeAllowances()
        #expect(rows.rows.contains { $0.credentialKey == "codex:sign-in" && $0.state.status == .available })
        #expect(rows.rows.first { $0.credentialKey == "claude:sign-in" }?.state.isOut == true)
        #expect(rows.anyOut)
    }

    @Test func aChangeIsBroadcastAndAPhoneMayAskAndMarkAvailable() async throws {
        let (core, _, _) = try core()
        let heard = RuntimeStatesHeard()
        await core.setBroadcaster { method, params in
            guard method == DaemonAPI.Notification.runtimesAllowancesChanged, let params,
                  let rows = try? params.decode(RuntimeAllowances.self) else { return }
            heard.append(rows.anyOut)
        }
        await core.setAllowanceState(claudeOut(at: Date()))
        await eventually("the window heard claude is out") { heard.all.last == true }
        _ = await core.markRuntimeAvailable(credentialKey: "claude:sign-in")
        // The shared timeout, not a shorter one of its own: a runtime's state is
        // broadcast at most once a second, and a change inside that second is held and
        // sent from a task a second later, so this second notification is not due
        // immediately. Under a full parallel suite that hold lands well past five
        // seconds, and a wait that outlasted it failed a run that had nothing wrong
        // with it (2026-09-30).
        await eventually("the window heard it is back") { heard.all.last == false }
        #expect(ConnectionRole.device.allows(DaemonAPI.Method.runtimesAllowances))
        #expect(ConnectionRole.device.allows(DaemonAPI.Method.runtimesMarkAvailable))
    }

    @Test func grokIsAskedForWhatIsLeftWithNoPool() async throws {
        var grok = FakeACPAgent.Script()
        grok.billing = [
            "config": [
                "creditUsagePercent": 72.0,
                "currentPeriod": ["type": "USAGE_PERIOD_TYPE_WEEKLY",
                                  "start": "2026-09-27T19:39:58.662818+00:00",
                                  "end": "2026-10-04T19:39:58.662818+00:00"],
            ],
            "subscription_tier": "SuperGrok",
        ]
        let (core, _, _) = try core(launcher: FakeLauncher(script: grok))
        await core.measureAllowances()
        #expect(await state(core, "grok:sign-in")?.reading?.window == "weekly")
    }
}

/// What `runtimes/allowancesChanged` carried, in order. The broadcaster runs anywhere.
private final class RuntimeStatesHeard: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [Bool] = []
    func append(_ value: Bool) { lock.lock(); seen.append(value); lock.unlock() }
    var all: [Bool] { lock.lock(); defer { lock.unlock() }; return seen }
}
