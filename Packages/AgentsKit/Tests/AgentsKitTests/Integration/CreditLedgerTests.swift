import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// US2 of 052: credit on a key is counted, and stops being used when it is gone, before
/// the provider says so (FR-001b, FR-001c).
@Suite("The credit ledger", .timeLimit(.minutes(1)))
struct CreditLedgerTests {
    private let copilot = PoolEntry(runtimeID: "copilot", payment: .allowance(label: nil))
    private let claude = PoolEntry(runtimeID: "claude", payment: .allowance(label: "Max plan"))

    private func usd(_ amount: Decimal) -> Cost { Cost(amount: amount, currency: "USD") }

    /// Credit on a key: Gemini's, the one key this Mac lends (046; Codex's went in 047).
    private func geminiKey(_ payment: Payment) -> PoolEntry {
        PoolEntry(runtimeID: "gemini", payment: payment, credentialRef: CredentialKind.geminiAPIKey.rawValue)
    }

    private func costing(_ amount: Decimal?) -> FakeACPAgent.Script {
        var script = FakeACPAgent.Script()
        script.usage = amount.map { ["totalTokens": 10, "cost": ["amount": .double(NSDecimalNumber(decimal: $0).doubleValue), "currency": "USD"]] }
            ?? ["totalTokens": 10]
        return script
    }

    private func core(default script: FakeACPAgent.Script = .init(), then: [FakeACPAgent.Script] = [],
                      clock: TestClock = TestClock()) async throws -> (DaemonCore, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("CreditLedger-\(UUID().uuidString)", isDirectory: true)
        let work = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let locations = StoreLocations(root: root)
        var discovery = RuntimeDiscovery.findsEverything
        for runtime in ["gemini", "codex"] {
            let current = locations.tools.appendingPathComponent("\(runtime)/current", isDirectory: true)
            try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
            try Data().write(to: current.appendingPathComponent("ok"))
        }
        discovery.macToolsHome = locations.tools.path
        let core = DaemonCore(store: try AgentStore(locations: locations), locations: locations, discovery: discovery,
                              launcher: FakeLauncher(script: script, then: then), now: { clock.now })
        try await core.lendCredential(.init(runtime: "gemini", secret: try #require(Secret(LendTests.geminiKey))),
                                      connection: nil)
        return (core, work)
    }

    private func row(_ core: DaemonCore, _ runtimeID: String) async -> PoolStatus.Row? {
        await core.poolStatus().rows.first { $0.entry.runtimeID == runtimeID }
    }

    @Test func prepaidCreditIsUsedUpByWhatTheTurnsCostBeforeAnyRefusal() async throws {
        let clock = TestClock()
        let (core, work) = try await core(default: costing(0.03), clock: clock)
        let key = geminiKey(.prepaid(amount: usd(0.05), expires: nil))
        _ = try await core.setPool(PoolSettings(isOn: true, entries: [key, copilot]))
        let id = try await core.start(.init(runtimeID: "gemini", cwd: work, prompt: "one"))
        // The turn and the app's ask for a report cost $0.03 each: $0.06 of $0.05.
        await eventually("the credit is used up") { await row(core, "gemini")?.state.isOut == true }
        let keyed = try #require(await row(core, "gemini"))
        guard case .out(nil, nil, .creditUsedUp) = keyed.state.status else { Issue.record("\(keyed.state.status)"); return }
        #expect(keyed.state.spent == .known(usd(0.06)))
        #expect(PoolWords.state(keyed.state, now: clock.now) == "Credit used up")

        // Never reset by a clock: two days on, still used up.
        clock.advance(by: 2 * 86400)
        #expect(await row(core, "gemini")?.state.isOut == true)
        // The chat itself stays where it is (065).
        #expect(await core.agent(id)?.runtimeID == "gemini")
    }

    @Test func aGrantPastItsDateIsOutAtOnce() async throws {
        let clock = TestClock()
        let expired = geminiKey(.freeCredit(amount: usd(5), expires: clock.now.addingTimeInterval(-86400)))
        var spent = FakeACPAgent.Script()
        spent.promptResultMeta = try SessionFailureDecodingTests.fixture("quota-exhausted")
        let (core, work) = try await core(then: [spent], clock: clock)
        _ = try await core.setPool(PoolSettings(isOn: true, entries: [claude, expired, copilot]))
        let keyed = try #require(await row(core, "gemini"))
        #expect(PoolWords.state(keyed.state, now: clock.now) == "Free credit expired")
        _ = (work, spent)
    }

    @Test func geminisFreeTierShowsMidnightPacificButStaysOutUntilChecked() async throws {
        let clock = TestClock()
        var refused = FakeACPAgent.Script()
        refused.promptError = JSONRPCError(code: 429, message: "You have exhausted your daily quota on this model.")
        let (core, work) = try await core(then: [refused], clock: clock)
        let gemini = PoolEntry(runtimeID: "gemini", payment: .freeTier(reset: .gemini),
                               credentialRef: CredentialKind.geminiAPIKey.rawValue)
        _ = try await core.setPool(PoolSettings(isOn: false, entries: [gemini]))
        let id = try await core.start(.init(runtimeID: "gemini", cwd: work, prompt: "go"))
        await eventually("the turn ended") { await core.agent(id)?.endedReason != nil }
        let out = try #require(await row(core, "gemini"))
        let back = try #require(out.state.returnsAt)
        var pacific = Calendar(identifier: .gregorian)
        pacific.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        #expect(pacific.component(.hour, from: back) == 0 && pacific.component(.minute, from: back) == 0)

        // The reset is shown, not believed: out until a check or a turn works.
        clock.now = back.addingTimeInterval(1)
        #expect(await row(core, "gemini")?.state.isOut == true)
    }

    @Test func aRuntimeThatSaysNothingOfCostIsSpendingNotKnown() async throws {
        let (core, work) = try await core(default: costing(nil))
        _ = try await core.setPool(PoolSettings(isOn: true, entries: [geminiKey(.prepaid(amount: usd(10), expires: nil)), copilot]))
        let id = try await core.start(.init(runtimeID: "gemini", cwd: work, prompt: "go"))
        await eventually("the turn ended") { await core.agent(id)?.endedReason != nil }
        await eventually("spending is unknown") { await row(core, "gemini")?.state.spent == .unknown }
        let keyed = try #require(await row(core, "gemini"))
        #expect(PoolWords.payment(keyed.entry.payment, spent: keyed.state.spent) == "Prepaid credit · spending not known")
        #expect(!keyed.state.isOut)
    }

    @Test func usedUpCreditComesBackOnlyWhenThePersonSaysSo() async throws {
        let (core, work) = try await core(default: costing(0.03))
        let key = geminiKey(.prepaid(amount: usd(0.05), expires: nil))
        _ = try await core.setPool(PoolSettings(isOn: true, entries: [key, copilot]))
        _ = try await core.start(.init(runtimeID: "gemini", cwd: work, prompt: "one"))
        await eventually("the credit is used up") { await row(core, "gemini")?.state.isOut == true }

        // Marked available: tried again, even though the ledger says it is spent.
        let marked = await core.markPoolEntryAvailable(key.id)
        let keyed = try #require(marked.rows.first { $0.entry.runtimeID == "gemini" })
        #expect(keyed.state.status == .available)
        // Topped up: counted from nothing again, so the new credit is not used up at once.
        #expect(keyed.state.spent == .known(nil))
    }

    @Test func raisingTheAmountBringsItBack() async throws {
        let (core, work) = try await core(default: costing(0.03))
        var key = geminiKey(.prepaid(amount: usd(0.05), expires: nil))
        _ = try await core.setPool(PoolSettings(isOn: true, entries: [key, copilot]))
        _ = try await core.start(.init(runtimeID: "gemini", cwd: work, prompt: "one"))
        await eventually("the credit is used up") { await row(core, "gemini")?.state.isOut == true }

        key.payment = .prepaid(amount: usd(1), expires: nil)
        let status = try await core.setPool(PoolSettings(isOn: true, entries: [key, copilot]))
        #expect(status.rows.first { $0.entry.runtimeID == "gemini" }?.state.status == .available)
        #expect(await core.eventLog.events.contains { $0.name == "cost.allowance_back" })
    }
}

/// A clock a test moves by hand.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_790_000_000)

    var now: Date {
        get { lock.lock(); defer { lock.unlock() }; return current }
        set { lock.lock(); current = newValue; lock.unlock() }
    }

    func advance(by seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}
