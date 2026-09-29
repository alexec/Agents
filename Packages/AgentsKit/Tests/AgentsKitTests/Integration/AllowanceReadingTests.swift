import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// What is left of a plan window, as Claude and Grok say it, shown on the Pool page and
/// never used to decide whether a chat runs.
@Suite("What is left of an allowance")
struct AllowanceReadingTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let claude = PoolEntry(runtimeID: "claude", payment: .allowance(label: nil))
    private let grok = PoolEntry(runtimeID: "grok", payment: .allowance(label: nil))

    /// Grok 0.x's own answer to `_x.ai/billing`, from a real account on 2026-09-28.
    private let grokAnswer: JSONValue = [
        "config": [
            "creditUsagePercent": 72.0,
            "currentPeriod": ["type": "USAGE_PERIOD_TYPE_WEEKLY",
                              "start": "2026-09-27T19:39:58.662818+00:00",
                              "end": "2026-10-04T19:39:58.662818+00:00"],
            "onDemandCap": ["val": 0], "onDemandUsed": ["val": 0], "prepaidBalance": ["val": 0],
            "isUnifiedBillingUser": true,
            "billingPeriodStart": "2026-09-27T19:39:58.662818+00:00",
            "billingPeriodEnd": "2026-10-04T19:39:58.662818+00:00",
        ],
        "subscription_tier": "SuperGrok",
    ]

    private func core(script: FakeACPAgent.Script = .init()) throws -> (DaemonCore, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AllowanceReading-\(UUID().uuidString)", isDirectory: true)
        let work = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let locations = StoreLocations(root: root)
        let core = DaemonCore(store: try AgentStore(locations: locations), locations: locations,
                              discovery: .findsEverything, launcher: FakeLauncher(script: script))
        return (core, work)
    }

    // MARK: Reading the runtimes

    @Test func grokSaysHowMuchOfTheWeekIsUsed() throws {
        let reading = try #require(AllowanceReading.grokBilling(grokAnswer, at: now))
        #expect(reading.window == "weekly")
        #expect(abs((reading.left ?? 0) - 0.28) < 0.0001)
        #expect(reading.resetsAt == ISO8601DateFormatter().date(from: "2026-10-04T19:39:58Z"))
        #expect(!reading.spent)
    }

    @Test func groksOlderShapeIsReadInCents() throws {
        let older: JSONValue = ["config": ["monthlyLimit": ["val": 2000], "used": ["val": 500],
                                           "billingPeriodEnd": "2026-10-01T00:00:00Z"]]
        let reading = try #require(AllowanceReading.grokBilling(older, at: now))
        #expect(reading.window == "monthly")
        #expect(reading.used == 0.25)
        #expect(AllowanceReading.grokBilling(["config": .null], at: now) == nil)
    }

    @Test func claudesWindowWithoutAnAmountStillSaysWhenItResets() throws {
        let back = now.addingTimeInterval(3600)
        let refused = try #require(AllowanceReading.claude(
            RateLimitInfo(status: "rejected", resetsAt: back, rateLimitType: "seven_day"), at: now))
        #expect(refused.left == 0)
        #expect(PoolWords.reading(refused, now: now)?.hasPrefix("None left this week · resets ") == true)

        let quiet = try #require(AllowanceReading.claude(
            RateLimitInfo(status: "allowed", resetsAt: back, rateLimitType: "five_hour"), at: now))
        #expect(quiet.left == nil)
        #expect(PoolWords.reading(quiet, now: now)?.hasPrefix("Of the 5-hour window · resets ") == true)

        #expect(AllowanceReading.claude(RateLimitInfo(status: "allowed"), at: now) == nil)
    }

    @Test func claudesUtilizationIsAFraction() throws {
        let fraction = try #require(AllowanceReading.claude(RateLimitInfo(utilization: 0.4), at: now))
        #expect(PoolWords.reading(fraction, now: now)?.hasPrefix("60% left") == true)
        // A percentage is never shown as more than all of it.
        let percent = try #require(AllowanceReading.claude(RateLimitInfo(utilization: 40), at: now))
        #expect(percent.used == 0.4)
    }

    @Test func aWindowThatHasResetSaysNothing() {
        let old = AllowanceReading(window: "five_hour", used: 0.9, resetsAt: now.addingTimeInterval(-1),
                                   at: now.addingTimeInterval(-3600))
        #expect(PoolWords.reading(old, now: now) == nil)
        #expect(PoolWords.reading(nil, now: now) == nil)
    }

    // MARK: The daemon

    @Test func claudesWindowIsKeptOnItsCredentialAndChangesNothingElse() async throws {
        let (core, work) = try core()
        let id = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "go"))
        let back = Date().addingTimeInterval(3600)
        await core.notePlanWindow(RateLimitInfo(status: "allowed", resetsAt: back, rateLimitType: "five_hour",
                                                utilization: 0.97), agentID: id)
        let state = try #require(await core.allowanceStates().first { $0.credentialKey == "claude:sign-in" })
        #expect(state.reading?.window == "five_hour")
        #expect(state.reading?.used == 0.97)
        // Nearly spent is still available: a reading never decides.
        #expect(state.status == .available)
        let row = try #require(await core.runtimeAllowances().rows.first { $0.credentialKey == "claude:sign-in" })
        #expect(row.state.reading == state.reading)
    }

    @Test func grokIsAskedWhenItsStateIsLookedAt() async throws {
        let (core, _) = try core(script: .init(billing: grokAnswer))
        await core.measureAllowances()
        let grokState = try #require(await core.allowanceStates().first { $0.credentialKey == "grok:sign-in" })
        #expect(grokState.reading?.window == "weekly")
        #expect(grokState.status == .available)
        // Claude is not asked: it says it during turns.
        #expect(await core.allowanceStates().first { $0.credentialKey == "claude:sign-in" } == nil)
    }

    @Test func aRecentReadingIsNotAskedForAgain() async throws {
        let launcher = FakeLauncher(script: .init(billing: grokAnswer))
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AllowanceReading-\(UUID().uuidString)", isDirectory: true)
        let locations = StoreLocations(root: root)
        let core = DaemonCore(store: try AgentStore(locations: locations), locations: locations,
                              discovery: .findsEverything, launcher: launcher)
        await core.measureAllowances()
        await core.measureAllowances()
        #expect(launcher.launchCount == 1)
    }

    @Test func aGrokWithoutBillingLeavesNoReading() async throws {
        let (core, _) = try core()
        await core.measureAllowances()
        #expect(await core.allowanceStates().allSatisfy { $0.reading == nil })
    }

    @Test func theLaterReadingCrossesToAnotherHostWhateverItsStatus() async throws {
        let (core, _) = try core()
        let later = Date()
        var mine = AllowanceState(credentialKey: "claude:sign-in", entryID: claude.id, since: later)
        mine.reading = AllowanceReading(window: "five_hour", used: 0.2, at: later.addingTimeInterval(-600))
        await core.setAllowanceState(mine)

        var theirs = AllowanceState(credentialKey: "claude:sign-in", entryID: UUID(), since: later.addingTimeInterval(-60))
        theirs.reading = AllowanceReading(window: "five_hour", used: 0.5, at: later)
        #expect(await core.applyAllowances([theirs]))
        let kept = try #require(await core.allowanceStates().first)
        #expect(kept.since == later)
        #expect(kept.reading?.used == 0.5)
        // The same again is not news, or two hosts would pass it back and forth.
        #expect(await core.applyAllowances([theirs]) == false)
    }
}
