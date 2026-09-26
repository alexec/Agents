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

    private func codexKey(_ payment: Payment) -> PoolEntry {
        PoolEntry(runtimeID: "codex", payment: payment, credentialRef: CredentialKind.openAIAPIKey.rawValue)
    }

    private func costing(_ amount: Decimal?) -> FakeACPAgent.Script {
        var script = FakeACPAgent.Script()
        script.usage = amount.map { ["totalTokens": 10, "cost": ["amount": .double(NSDecimalNumber(decimal: $0).doubleValue), "currency": "USD"]] }
            ?? ["totalTokens": 10]
        return script
    }

    private func core(default script: FakeACPAgent.Script = .init(), then: [FakeACPAgent.Script] = [],
                      clock: TestClock = TestClock()) throws -> (DaemonCore, URL) {
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
        return (core, work)
    }

    private func row(_ core: DaemonCore, _ runtimeID: String) async -> PoolStatus.Row? {
        await core.poolStatus().rows.first { $0.entry.runtimeID == runtimeID }
    }

    @Test func prepaidCreditIsUsedUpByWhatTheTurnsCostBeforeAnyRefusal() async throws {
        let clock = TestClock()
        let (core, work) = try core(default: costing(0.03), clock: clock)
        let key = codexKey(.prepaid(amount: usd(0.05), expires: nil))
        _ = try await core.setPool(PoolSettings(isOn: true, entries: [key, copilot]))
        let id = try await core.start(.init(runtimeID: "codex", cwd: work, prompt: "one"))
        // The turn and the app's ask for a report cost $0.03 each: $0.06 of $0.05.
        await eventually("the credit is used up") { await row(core, "codex")?.state.isOut == true }
        let codex = try #require(await row(core, "codex"))
        guard case .out(nil, nil, .creditUsedUp) = codex.state.status else { Issue.record("\(codex.state.status)"); return }
        #expect(codex.state.spent == .known(usd(0.06)))
        #expect(PoolWords.state(codex.state, now: clock.now) == "Credit used up")

        // Never reset by a clock: two days on, still used up.
        clock.advance(by: 2 * 86400)
        #expect(await row(core, "codex")?.state.isOut == true)

        // The next turn goes to Copilot first, without asking Codex again.
        await eventually("the chat is quiet") { await core.agent(id)?.state == .finished }
        try await core.prompt(.init(agentID: id, text: "two"))
        await eventually("it moved to Copilot") { await core.agent(id)?.runtimeID == "copilot" }
    }

    @Test func aGrantPastItsDateIsOutAtOnce() async throws {
        let clock = TestClock()
        let expired = codexKey(.freeCredit(amount: usd(5), expires: clock.now.addingTimeInterval(-86400)))
        var spent = FakeACPAgent.Script()
        spent.promptResultMeta = try SessionFailureDecodingTests.fixture("quota-exhausted")
        let (core, work) = try core(then: [spent], clock: clock)
        _ = try await core.setPool(PoolSettings(isOn: true, entries: [claude, expired, copilot]))
        let codex = try #require(await row(core, "codex"))
        #expect(PoolWords.state(codex.state, now: clock.now) == "Free credit expired")

        // Never tried: Claude's spent chat goes past it.
        let id = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "go"))
        await eventually("it moved to Copilot") { await core.agent(id)?.runtimeID == "copilot" }
    }

    @Test func geminisFreeTierComesBackAtMidnightPacific() async throws {
        let clock = TestClock()
        var refused = FakeACPAgent.Script()
        refused.promptError = JSONRPCError(code: 429, message: "You have exhausted your daily quota on this model.")
        let (core, work) = try core(then: [refused], clock: clock)
        try await core.lendCredential(.init(runtime: "gemini", secret: try #require(Secret(LendTests.geminiKey))),
                                      connection: nil)
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

        clock.now = back.addingTimeInterval(1)
        #expect(await row(core, "gemini")?.state.status == .available)
    }

    @Test func aRuntimeThatSaysNothingOfCostIsSpendingNotKnown() async throws {
        let (core, work) = try core(default: costing(nil))
        _ = try await core.setPool(PoolSettings(isOn: true, entries: [codexKey(.prepaid(amount: usd(10), expires: nil)), copilot]))
        let id = try await core.start(.init(runtimeID: "codex", cwd: work, prompt: "go"))
        await eventually("the turn ended") { await core.agent(id)?.endedReason != nil }
        await eventually("spending is unknown") { await row(core, "codex")?.state.spent == .unknown }
        let codex = try #require(await row(core, "codex"))
        #expect(PoolWords.payment(codex.entry.payment, spent: codex.state.spent) == "Prepaid credit · spending not known")
        #expect(!codex.state.isOut)
    }

    @Test func usedUpCreditComesBackOnlyWhenThePersonSaysSo() async throws {
        let (core, work) = try core(default: costing(0.03))
        let key = codexKey(.prepaid(amount: usd(0.05), expires: nil))
        _ = try await core.setPool(PoolSettings(isOn: true, entries: [key, copilot]))
        _ = try await core.start(.init(runtimeID: "codex", cwd: work, prompt: "one"))
        await eventually("the credit is used up") { await row(core, "codex")?.state.isOut == true }

        // Marked available: tried again, even though the ledger says it is spent.
        let marked = await core.markPoolEntryAvailable(key.id)
        let codex = try #require(marked.rows.first { $0.entry.runtimeID == "codex" })
        #expect(codex.state.status == .available)
        // Topped up: counted from nothing again, so the new credit is not used up at once.
        #expect(codex.state.spent == .known(nil))
    }

    @Test func raisingTheAmountBringsItBack() async throws {
        let (core, work) = try core(default: costing(0.03))
        var key = codexKey(.prepaid(amount: usd(0.05), expires: nil))
        _ = try await core.setPool(PoolSettings(isOn: true, entries: [key, copilot]))
        _ = try await core.start(.init(runtimeID: "codex", cwd: work, prompt: "one"))
        await eventually("the credit is used up") { await row(core, "codex")?.state.isOut == true }

        key.payment = .prepaid(amount: usd(1), expires: nil)
        let status = try await core.setPool(PoolSettings(isOn: true, entries: [key, copilot]))
        #expect(status.rows.first { $0.entry.runtimeID == "codex" }?.state.status == .available)
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
