import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// Once 052's credit ledger (US2). Since 065 the app keeps no ledger: a key's credit is
/// used up when the provider says so. What stays is Gemini's free tier, shown with its
/// reset and checked like any runtime.
@Suite("A key's free tier", .timeLimit(.minutes(1)))
struct GeminiFreeTierTests {
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

    private func row(_ core: DaemonCore, _ runtimeID: String) async -> RuntimeAllowances.Row? {
        await core.runtimeAllowances().rows.first { $0.runtimeID == runtimeID }
    }

    @Test func geminisFreeTierShowsMidnightPacificButStaysOutUntilChecked() async throws {
        let clock = TestClock()
        var refused = FakeACPAgent.Script()
        refused.promptError = JSONRPCError(code: 429, message: "You have exhausted your daily quota on this model.")
        let (core, work) = try await core(then: [refused], clock: clock)
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
