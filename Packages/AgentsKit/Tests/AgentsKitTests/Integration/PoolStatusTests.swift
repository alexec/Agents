import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// US3 of 052: one place that says which runtimes are out, until when, and what moved.
@Suite("The Pool page's state", .timeLimit(.minutes(1)))
struct PoolStatusTests {
    private let claude = PoolEntry(runtimeID: "claude", payment: .allowance(label: "Max plan"))
    private let codex = PoolEntry(runtimeID: "codex", payment: .allowance(label: "ChatGPT plan"))
    private let copilot = PoolEntry(runtimeID: "copilot", payment: .allowance(label: nil))

    private func core(clock: TestClock = TestClock(), launcher: FakeLauncher = FakeLauncher()) throws
        -> (DaemonCore, URL, StoreLocations) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("PoolStatus-\(UUID().uuidString)", isDirectory: true)
        let work = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let locations = StoreLocations(root: root)
        var discovery = RuntimeDiscovery.findsEverything
        let current = locations.tools.appendingPathComponent("codex/current", isDirectory: true)
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        try Data().write(to: current.appendingPathComponent("ok"))
        discovery.macToolsHome = locations.tools.path
        let core = DaemonCore(store: try AgentStore(locations: locations), locations: locations, discovery: discovery,
                              launcher: launcher, now: { clock.now })
        return (core, work, locations)
    }

    private func out(_ entry: PoolEntry, until: Date?, at: Date) -> AllowanceState {
        var state = AllowanceState(credentialKey: AllowanceState.credentialKey(for: entry), entryID: entry.id, since: at)
        state.markOut(.allowanceSpent, until: until, payment: entry.payment, now: at, from: .typedFailure)
        return state
    }

    private func line(_ status: PoolStatus, _ runtimeID: String) -> String? {
        status.rows.first { $0.entry.runtimeID == runtimeID }.map { $0.line(now: status.at) }
    }

    @Test func eachStateReadsInWordsAndAnyOutFollowsThem() async throws {
        let clock = TestClock()
        let (core, _, _) = try core(clock: clock)
        _ = try await core.setPool(PoolSettings(isOn: true, entries: [claude, codex, copilot]))
        #expect(await core.poolStatus().anyOut == false)

        await core.setAllowanceState(out(claude, until: clock.now.addingTimeInterval(3600), at: clock.now))
        await core.setAllowanceState(out(codex, until: nil, at: clock.now))
        var limited = AllowanceState(credentialKey: "copilot:sign-in", entryID: copilot.id, since: clock.now)
        limited.rateLimited(now: clock.now, retryAt: clock.now.addingTimeInterval(120))
        await core.setAllowanceState(limited)

        let status = await core.poolStatus()
        #expect(status.anyOut)
        #expect(line(status, "claude")?.hasPrefix("Out · reset ") == true)
        #expect(line(status, "codex")?.hasPrefix("Out since ") == true)
        #expect(line(status, "codex")?.contains("trying again after") == true)
        #expect(line(status, "copilot")?.hasPrefix("Rate limited · trying again at ") == true)
        #expect(status.countLine != nil)
    }

    @Test func eachEntryCountsTheChatsOnIt() async throws {
        let (core, work, _) = try core()
        _ = try await core.setPool(PoolSettings(isOn: true, entries: [claude, codex]))
        for prompt in ["one", "two"] { _ = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: prompt)) }
        _ = try await core.start(.init(runtimeID: "codex", cwd: work, prompt: "three"))
        let status = await core.poolStatus()
        #expect(status.rows.first { $0.entry.runtimeID == "claude" }?.chats == 2)
        #expect(status.rows.first { $0.entry.runtimeID == "codex" }?.chats == 1)
    }

    @Test func switchesFromTheLastDayUnlessThirtyAreAskedFor() async throws {
        let clock = TestClock()
        let (core, _, locations) = try core(clock: clock)
        let store = PoolStore(locations: locations)
        for hoursAgo: Double in [1, 50, 24 * 40] {
            try store.append(SwitchRecord(at: clock.now.addingTimeInterval(-hoursAgo * 3600), agentID: UUID(),
                                          from: .init(runtimeID: "claude"), to: .init(runtimeID: "codex"),
                                          reason: .allowanceSpent, billing: codex.payment))
        }
        #expect(await core.poolStatus().switches.count == 1)
        #expect(await core.poolStatus(days: 30).switches.count == 2)
    }

    @Test func markAvailableIsThePersonsWordAndCanBeSaidTwice() async throws {
        let clock = TestClock()
        let (core, _, _) = try core(clock: clock)
        _ = try await core.setPool(PoolSettings(isOn: true, entries: [claude, codex]))
        await core.setAllowanceState(out(claude, until: nil, at: clock.now))
        let first = await core.markPoolEntryAvailable(claude.id)
        let second = await core.markPoolEntryAvailable(claude.id)
        for status in [first, second] {
            let row = try #require(status.rows.first { $0.entry.runtimeID == "claude" })
            #expect(row.state.status == .available)
            #expect(row.state.learnedFrom == .person)
            #expect(!status.anyOut)
        }
        // Said back once, not once per press.
        #expect(await core.eventLog.events.count { $0.name == "cost.allowance_back" } == 1)
        // A paired phone may say it too.
        #expect(ConnectionRole.device.allows(DaemonAPI.Method.poolMarkAvailable))
    }

    @Test func aBurstOfChangesIsOneBroadcastASecond() async throws {
        let (core, _, _) = try core()
        let heard = PoolBroadcasts()
        await core.setBroadcaster { method, params in
            guard method == DaemonAPI.Notification.poolChanged, let params,
                  let status = try? JSONDecoder().decode(PoolStatus.self, from: JSONEncoder().encode(params)) else { return }
            heard.append(status.settings.entries.count)
        }
        let entries = [claude, codex, copilot]
        for count in 1...3 {
            _ = try await core.setPool(PoolSettings(isOn: true, entries: Array(entries.prefix(count))))
        }
        // Whatever the machine's speed: never two within the second, never more than
        // there were changes, and the last carries the pool as it ended.
        await eventually("the last one carried the pool as it ended") { heard.all.last == 3 }
        try await Task.sleep(for: .milliseconds(1200))
        #expect(heard.all.count <= 3)
        #expect(heard.all.last == 3)
        for gap in heard.gaps { #expect(gap >= .milliseconds(950), "\(gap)") }
    }

    @Test func aPassingCheckIsSaidWithoutARelaunch() async throws {
        let clock = TestClock()
        var answersOK = FakeACPAgent.Script()
        answersOK.updates = [["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": "OK"]]]
        let launcher = FakeLauncher(script: answersOK)
        let (core, _, _) = try core(clock: clock, launcher: launcher)
        _ = try await core.setPool(PoolSettings(isOn: true, entries: [claude, codex]))
        await core.setAllowanceState(out(claude, until: clock.now.addingTimeInterval(600), at: clock.now))
        let heard = PoolBroadcasts()
        await core.setBroadcaster { method, params in
            guard method == DaemonAPI.Notification.poolChanged, let params,
                  let status = try? JSONDecoder().decode(PoolStatus.self, from: JSONEncoder().encode(params)) else { return }
            heard.append(status.anyOut ? 1 : 0)
        }
        // The provider's reset passing is shown, not believed: nothing is started.
        clock.advance(by: 601)
        await core.tickWorkflows(now: clock.now)
        #expect(await core.allowanceStates().first { $0.credentialKey == "claude:sign-in" }?.isOut == true)
        #expect(launcher.launchCount == 0)

        clock.advance(by: AllowanceState.retryWithoutATime)
        await core.tickWorkflows(now: clock.now)
        await eventually("the window was told it is back", within: .seconds(30)) { heard.all.last == 0 }
        #expect(launcher.launchCount == 1)
        #expect(await core.allowanceStates().first { $0.credentialKey == "claude:sign-in" }?.status == .available)
        #expect(await core.eventLog.events.contains { $0.name == "cost.allowance_back" && $0.details["how"] == "check" })
    }

    @Test func aFailingCheckKeepsItOutForAnotherFourHours() async throws {
        let clock = TestClock()
        var refuses = FakeACPAgent.Script()
        refuses.promptError = JSONRPCError(code: -32603, message: "Internal error")
        let launcher = FakeLauncher(script: refuses)
        let (core, _, _) = try core(clock: clock, launcher: launcher)
        _ = try await core.setPool(PoolSettings(isOn: true, entries: [claude, codex]))
        let start = clock.now
        await core.setAllowanceState(out(claude, until: nil, at: start))
        clock.advance(by: AllowanceState.retryWithoutATime + 1)
        let checkedAt = clock.now
        await core.tickWorkflows(now: checkedAt)
        await eventually("the check was put off", within: .seconds(30)) {
            guard case .out(_, let retry?, _) = await core.allowanceStates()
                .first(where: { $0.credentialKey == "claude:sign-in" })?.status else { return false }
            return retry > checkedAt
        }
        let state = try #require(await core.allowanceStates().first { $0.credentialKey == "claude:sign-in" })
        guard case .out(nil, let retry?, .allowanceSpent) = state.status else { Issue.record("\(state.status)"); return }
        #expect(retry == checkedAt.addingTimeInterval(AllowanceState.retryWithoutATime))
        #expect(launcher.launchCount == 1)
        // The same heartbeat again starts nothing.
        await core.tickWorkflows(now: checkedAt.addingTimeInterval(60))
        try await Task.sleep(for: .milliseconds(200))
        #expect(launcher.launchCount == 1)
    }
}

/// What `pool/changed` carried, in order. The broadcaster runs wherever the daemon is.
private final class PoolBroadcasts: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [(value: Int, at: ContinuousClock.Instant)] = []
    func append(_ value: Int) { lock.lock(); seen.append((value, .now)); lock.unlock() }
    var all: [Int] { lock.lock(); defer { lock.unlock() }; return seen.map(\.value) }
    /// The time between each broadcast and the one before it.
    var gaps: [Duration] {
        lock.lock(); defer { lock.unlock() }
        return zip(seen.dropFirst(), seen).map { $0.at - $1.at }
    }
}
