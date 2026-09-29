import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// US4 of 052: when every runtime in the pool is out, the chat waits for the next
/// availability check, and carries on once one passes, once.
@Suite("Waiting for an allowance", .timeLimit(.minutes(1)))
struct AllowanceWaitTests {
    private let claude = PoolEntry(runtimeID: "claude", payment: .allowance(label: "Max plan"))
    private let codex = PoolEntry(runtimeID: "codex", payment: .allowance(label: "ChatGPT plan"))
    /// When Claude's plan window says it is back (the fixture's `resetsAt`).
    private let back = Date(timeIntervalSince1970: 1_790_000_000)
    /// When both are checked: four hours after they went out, half an hour before `back`.
    private var checked: Date { back.addingTimeInterval(-1800 + AllowanceState.retryWithoutATime) }
    /// What a runtime says to the availability check, and to any turn after it.
    private static let answersOK: FakeACPAgent.Script = {
        var script = FakeACPAgent.Script()
        script.updates = [["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": "OK"]]]
        return script
    }()

    /// Claude spent with a known return; Codex spent with none.
    private func spentUntilBack() throws -> FakeACPAgent.Script {
        var script = FakeACPAgent.Script()
        script.promptResultMeta = try SessionFailureDecodingTests.fixture("quota-exhausted")
        script.usageMeta = try SessionFailureDecodingTests.fixture("claude-rate-limit-rejected")
        return script
    }

    private func spentNoTime() throws -> FakeACPAgent.Script {
        var script = FakeACPAgent.Script()
        script.promptResultMeta = try SessionFailureDecodingTests.fixture("quota-exhausted")
        return script
    }

    private func core(_ scripts: [FakeACPAgent.Script], clock: TestClock, root: URL? = nil)
        async throws -> (DaemonCore, URL, FakeLauncher) {
        let root = root ?? URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AllowanceWait-\(UUID().uuidString)", isDirectory: true)
        let work = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let locations = StoreLocations(root: root)
        var discovery = RuntimeDiscovery.findsEverything
        let current = locations.tools.appendingPathComponent("codex/current", isDirectory: true)
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        try Data().write(to: current.appendingPathComponent("ok"))
        discovery.macToolsHome = locations.tools.path
        let launcher = FakeLauncher(script: Self.answersOK, then: scripts)
        let core = DaemonCore(store: try AgentStore(locations: locations), locations: locations, discovery: discovery,
                              launcher: launcher, now: { clock.now })
        _ = await core.recover()
        _ = try await core.setPool(PoolSettings(isOn: true, entries: [claude, codex]))
        return (core, work, launcher)
    }

    private func notes(_ core: DaemonCore, _ id: UUID) async throws -> [String] {
        try await core.transcript(.init(agentID: id)).entries.compactMap {
            if case .runtimeNote(let text) = $0.kind { text } else { nil }
        }
    }

    /// Everyone out: Claude, back at `back`, then Codex, with no time. Both are checked at `checked`.
    private func everyoneOut() async throws -> (DaemonCore, UUID, TestClock, FakeLauncher, URL) {
        let clock = TestClock()
        clock.now = back.addingTimeInterval(-1800)
        let (core, work, launcher) = try await core([try spentUntilBack(), try spentNoTime()], clock: clock)
        let id = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "fix the redirect"))
        let waiting = await eventually("it is waiting") { await core.agent(id)?.allowanceWait != nil }
        if !waiting { Issue.record("notes: \(try await notes(core, id))") }
        return (core, id, clock, launcher, work.deletingLastPathComponent())
    }

    @Test func everyoneOutWaitsForTheFirstCheckAndSaysSo() async throws {
        let (core, id, _, launcher, _) = try await everyoneOut()
        let agent = try #require(await core.agent(id))
        let wait = try #require(agent.allowanceWait)
        // The next check, not the provider's reset: that is only shown.
        #expect(wait.runtimeID == "claude" && wait.resumeAt == checked)
        #expect(wait.text == "fix the redirect")
        // Waiting, not failed: stopped for its allowance, never finished.
        #expect(agent.state == .stopped && agent.endedReason == .allowanceSpent)
        #expect(try await notes(core, id).contains { $0.hasPrefix("Every runtime in the pool is out. This chat waits, and Claude is checked at ") })
        #expect(await core.poolStatus().waiting.map(\.agentID) == [id])
        #expect(launcher.launchCount == 2)
    }

    @Test func whenACheckPassesTheChatCarriesOnOnce() async throws {
        let (core, id, clock, launcher, _) = try await everyoneOut()
        // Not yet, and the provider's reset passing is not enough either.
        await core.tickWorkflows(now: clock.now)
        clock.now = back.addingTimeInterval(1)
        await core.tickWorkflows(now: clock.now)
        #expect(await core.agent(id)?.allowanceWait != nil)
        #expect(launcher.launchCount == 2)

        // Both checked; the chat goes on the next heartbeat after one passes.
        clock.now = checked.addingTimeInterval(1)
        await core.tickWorkflows(now: clock.now)
        await eventually("both were checked and are back") {
            await core.allowanceStates().allSatisfy { !$0.isOut }
        }
        #expect(launcher.launchCount == 4)
        // Its own runtime, Codex, is back too, so it carries on there with no switch.
        await core.tickWorkflows(now: clock.now)
        await eventually("it carried on with Codex") {
            await core.agent(id)?.runtimeID == "codex" && launcher.launchCount >= 5
        }
        await eventually("the turn ended") { await core.agent(id)?.endedReason == .endTurn }
        #expect(await core.agent(id)?.allowanceWait == nil)
        let sent = await launcher.allAgents[4].prompts
        #expect(sent.count == 1)
        // Typed once: the words are on the record once, however often they were sent.
        let typed = try await core.transcript(.init(agentID: id)).entries.count {
            if case .userMessage(let text, _, _) = $0.kind { text == "fix the redirect" } else { false }
        }
        #expect(typed == 1)
        let switches = try await core.transcript(.init(agentID: id)).entries.compactMap {
            if case .poolSwitch(let record) = $0.kind { record } else { nil }
        }
        #expect(switches.map(\.reason) == [.allowanceSpent])
        #expect(try await notes(core, id).contains(PoolWords.cameBack("codex")))

        // A later tick sends nothing again.
        let before = launcher.launchCount
        await core.tickWorkflows(now: clock.now.addingTimeInterval(60))
        try await Task.sleep(for: .milliseconds(200))
        #expect(launcher.launchCount <= before + 1, "only the app's own ask for a report may follow")
    }

    @Test(arguments: ["stop", "park", "archive"])
    func stoppingParkingOrArchivingDropsTheWait(how: String) async throws {
        let (core, id, clock, launcher, _) = try await everyoneOut()
        switch how {
        case "stop": try await core.stop(id)
        case "park": try await core.park(id)
        default: try await core.archive(id)
        }
        #expect(await core.agent(id)?.allowanceWait == nil)
        #expect(await core.poolStatus().waiting.isEmpty)
        clock.now = back.addingTimeInterval(1)
        await core.tickWorkflows(now: clock.now)
        try await Task.sleep(for: .milliseconds(200))
        #expect(launcher.launchCount == 2)
    }

    @Test func thePersonsNextPromptReplacesTheWait() async throws {
        let (core, id, _, _, _) = try await everyoneOut()
        try await core.prompt(.init(agentID: id, text: "something else"))
        // Whatever that turn does, the refused words are not waiting to go any more.
        await eventually("the prompt was taken") {
            (try? await core.transcript(.init(agentID: id)).entries.contains {
                if case .userMessage(let text, _, _) = $0.kind { text == "something else" } else { false }
            }) == true
        }
        #expect(await core.agent(id)?.allowanceWait?.text != "fix the redirect")
    }

    @Test func stopWaitingFromThePoolPage() async throws {
        let (core, id, _, _, _) = try await everyoneOut()
        await core.stopWaitingForAllowance(id)
        #expect(await core.agent(id)?.allowanceWait == nil)
        #expect(try await notes(core, id).contains(PoolWords.stoppedWaiting))
        #expect(ConnectionRole.device.allows(DaemonAPI.Method.poolStopWaiting))
    }

    @Test func withNoKnownReturnItStillWaitsForTheNextCheck() async throws {
        let clock = TestClock()
        let (core, work, _) = try await core([try spentNoTime(), try spentNoTime()], clock: clock)
        let id = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "go"))
        let waiting = await eventually("it is waiting") { await core.agent(id)?.allowanceWait != nil }
        if !waiting { Issue.record("notes: \(try await notes(core, id))") }
        #expect(await core.agent(id)?.allowanceWait?.resumeAt == clock.now.addingTimeInterval(AllowanceState.retryWithoutATime))
        #expect(try await notes(core, id).contains(PoolWords.everyoneOutNoTime) == false)
        #expect(await core.agent(id)?.endedReason == .allowanceSpent)
    }

    @Test func aRestartKeepsTheWaitAndStillCarriesOn() async throws {
        let (first, id, clock, _, root) = try await everyoneOut()
        // A daemon that restarts has written its records first: saves go out on a queue,
        // so wait for it, as a real exit would, before the next one reads the disk.
        let saving = await first.saveTail
        await saving?.value
        clock.now = checked.addingTimeInterval(1)
        let (second, _, launcher) = try await core([], clock: clock, root: root)
        #expect(await second.agent(id)?.allowanceWait?.runtimeID == "claude")
        await second.tickWorkflows(now: clock.now)
        await eventually("the checks passed after the restart", within: .seconds(30)) {
            await second.allowanceStates().allSatisfy { !$0.isOut }
        }
        await second.tickWorkflows(now: clock.now)
        await eventually("it carried on after the restart", within: .seconds(30)) {
            await second.agent(id)?.allowanceWait == nil && launcher.launchCount >= 3
        }
        #expect(await second.agent(id)?.allowanceWait == nil)
    }
}
