import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// T069 of 052: a server spends the Mac's plan through the relay, so what one learns
/// about that plan the other must know. The Mac's window carries `RuntimeAllowances.shared`
/// from one daemon to `pool/applyAllowances` on the other; two daemons stand in for the
/// Mac and a server here.
@Suite("Allowances shared with a server", .timeLimit(.minutes(1)))
struct ServerAllowanceTests {
    private let claude = PoolEntry(runtimeID: "claude", payment: .allowance(label: "Max plan"))
    private let codex = PoolEntry(runtimeID: "codex", payment: .allowance(label: "ChatGPT plan"))

    private func daemon(_ scripts: [FakeACPAgent.Script] = []) async throws -> (DaemonCore, URL, FakeLauncher) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ServerAllowance-\(UUID().uuidString)", isDirectory: true)
        let work = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let locations = StoreLocations(root: root)
        var discovery = RuntimeDiscovery.findsEverything
        for runtime in ["codex", "gemini"] {
            let current = locations.tools.appendingPathComponent("\(runtime)/current", isDirectory: true)
            try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
            try Data().write(to: current.appendingPathComponent("ok"))
        }
        discovery.macToolsHome = locations.tools.path
        let launcher = FakeLauncher(script: FakeACPAgent.Script(), then: scripts)
        let core = DaemonCore(store: try AgentStore(locations: locations), locations: locations,
                              discovery: discovery, launcher: launcher)
        return (core, work, launcher)
    }

    private func spent() throws -> FakeACPAgent.Script {
        var script = FakeACPAgent.Script()
        script.promptResultMeta = try SessionFailureDecodingTests.fixture("quota-exhausted")
        return script
    }

    @Test func aRelayedPlanSpentOnTheServerIsOutOnTheMac() async throws {
        let (mac, macWork, _) = try await daemon()
        let (server, serverWork, _) = try await daemon([try spent()])
        // A Mac chat on Codex, its turn done, before anything is known.
        let id = try await mac.start(.init(runtimeID: "codex", cwd: macWork, prompt: "one"))
        await eventually("it answered", within: .seconds(30)) {
            let agent = await mac.agent(id)
            return agent?.state == .finished && agent?.outcomeAsked == true
        }
        try await Task.sleep(for: .milliseconds(300))

        // The server's Codex runs on the Mac's ChatGPT plan, relayed, and is refused.
        _ = try await server.start(.init(runtimeID: "codex", cwd: serverWork, prompt: "go"))
        await eventually("the server knows") {
            await server.allowanceStates().contains { $0.credentialKey == "codex:sign-in" && $0.isOut }
        }

        // The window carries the server's word to the Mac.
        let shared = try #require(await server.runtimeAllowances().shared)
        #expect(await mac.applyAllowances(shared))
        #expect(await mac.allowanceStates().contains { $0.credentialKey == "codex:sign-in" && $0.isOut })
        #expect(await mac.runtimeAllowances().anyOut)
        #expect(await mac.eventLog.events.contains { $0.name == "cost.allowance_out" })
        // The Mac's chat is not moved by it (065): it stays on Codex.
        #expect(await mac.agent(id)?.runtimeID == "codex")
    }

    @Test func aKeyKeepsItsOwnState() async throws {
        let (mac, _, _) = try await daemon()
        var keyed = AllowanceState(credentialKey: "gemini:geminiAPIKey", entryID: UUID(), since: Date())
        keyed.markOut(.creditUsedUp, until: nil, payment: .prepaid(amount: nil, expires: nil), now: Date(), from: .ledger)
        #expect(!keyed.isShared)
        #expect(await mac.applyAllowances([keyed]) == false)
        #expect(await mac.allowanceStates().isEmpty)
    }

    @Test func theNewerWordWinsAndTheSameWordTwiceChangesNothing() async throws {
        let (mac, _, _) = try await daemon()
        let now = Date()
        var out = AllowanceState(credentialKey: "codex:sign-in", entryID: UUID(), since: now)
        out.markOut(.allowanceSpent, until: now.addingTimeInterval(3600), payment: codex.payment, now: now, from: .typedFailure)
        #expect(await mac.applyAllowances([out]))
        #expect(await mac.applyAllowances([out]) == false, "no ping-pong between the Mac and a server")

        var older = AllowanceState(credentialKey: "codex:sign-in", entryID: UUID(), since: now.addingTimeInterval(-60))
        older.markAvailable(now: now.addingTimeInterval(-60))
        #expect(await mac.applyAllowances([older]) == false)
        #expect(await mac.allowanceStates().first?.isOut == true)

        var back = AllowanceState(credentialKey: "codex:sign-in", entryID: UUID(), since: now)
        back.markAvailable(now: now.addingTimeInterval(60))
        #expect(await mac.applyAllowances([back]))
        #expect(await mac.allowanceStates().first?.isOut == false)
    }

    /// An entry nobody has used shows as available on the page, but that is not a word
    /// about the plan, and must never be carried over one that is.
    @Test func whatIsCarriedIsWhatWasRecordedNotTheRows() async throws {
        let (fresh, _, _) = try await daemon()
        let status = await fresh.runtimeAllowances()
        #expect(!status.rows.isEmpty)
        #expect(status.shared == [])
    }

    @Test func anyPersonsConnectionMayCarryItAndNoAgent() {
        #expect(ConnectionRole.device.allows(DaemonAPI.Method.poolApplyAllowances))
        #expect(!ConnectionRole.agent.allows(DaemonAPI.Method.poolApplyAllowances))
    }
}
