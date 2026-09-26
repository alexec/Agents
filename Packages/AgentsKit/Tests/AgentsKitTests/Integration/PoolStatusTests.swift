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

    private func core(clock: TestClock = TestClock()) throws -> (DaemonCore, URL, StoreLocations) {
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
                              launcher: FakeLauncher(), now: { clock.now })
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
        _ = limited.rateLimited(now: clock.now, retryAt: clock.now.addingTimeInterval(120), payment: copilot.payment)
        await core.setAllowanceState(limited)

        let status = await core.poolStatus()
        #expect(status.anyOut)
        #expect(line(status, "claude")?.hasPrefix("Out until ") == true)
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
        // The first at once; the other two held and sent as one, with the pool as it ended.
        #expect(heard.all == [1])
        await eventually("the held one went") { heard.all.count == 2 }
        #expect(heard.all == [1, 3])
        try await Task.sleep(for: .milliseconds(1200))
        #expect(heard.all.count == 2)
    }

    @Test func aReturnTimePassingIsSaidWithoutARelaunch() async throws {
        let clock = TestClock()
        let (core, _, _) = try core(clock: clock)
        _ = try await core.setPool(PoolSettings(isOn: true, entries: [claude, codex]))
        await core.setAllowanceState(out(claude, until: clock.now.addingTimeInterval(600), at: clock.now))
        let heard = PoolBroadcasts()
        await core.setBroadcaster { method, params in
            guard method == DaemonAPI.Notification.poolChanged, let params,
                  let status = try? JSONDecoder().decode(PoolStatus.self, from: JSONEncoder().encode(params)) else { return }
            heard.append(status.anyOut ? 1 : 0)
        }
        clock.advance(by: 601)
        await core.tickWorkflows(now: clock.now)
        await eventually("the window was told it is back") { heard.all.last == 0 }
        #expect(await core.allowanceStates().first { $0.credentialKey == "claude:sign-in" }?.status == .available)
        #expect(await core.eventLog.events.contains { $0.name == "cost.allowance_back" && $0.details["how"] == "time" })
    }
}

/// What `pool/changed` carried, in order. The broadcaster runs wherever the daemon is.
private final class PoolBroadcasts: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [Int] = []
    func append(_ value: Int) { lock.lock(); seen.append(value); lock.unlock() }
    var all: [Int] { lock.lock(); defer { lock.unlock() }; return seen }
}
