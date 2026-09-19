import Foundation
import Testing
@testable import AgentsKit

@Suite("What a turn used", .timeLimit(.minutes(1)))
struct TurnUsageTests {
    private func temporary() throws -> (StoreLocations, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsUsageTests-\(UUID().uuidString)", isDirectory: true)
        let work = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        return (StoreLocations(root: root), work)
    }

    private func core(_ launcher: FakeLauncher, locations: StoreLocations) throws -> DaemonCore {
        DaemonCore(store: try AgentStore(locations: locations),
                   locations: locations,
                   discovery: .findsEverything,
                   launcher: launcher)
    }

    @Test func theTurnsOwnUsageIsRecordedOnceAndAddedUp() async throws {
        let (locations, work) = try temporary()
        var script = FakeACPAgent.Script()
        // The shape the Claude adapter answered with on 2026-09-18.
        script.usage = ["inputTokens": 6, "outputTokens": 256, "totalTokens": 90229,
                        "cachedReadTokens": 69806, "cachedWriteTokens": 20161,
                        "cost": ["amount": 0.244, "currency": "USD"]]
        script.updates = [["sessionUpdate": "usage_update", "used": 30360, "size": 1000000]]
        let core = try core(FakeLauncher(script: script), locations: locations)

        let id = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "go"))
        try await Task.sleep(for: .milliseconds(300))

        let agent = await core.agent(id)
        #expect(agent?.usage?.used == 30360, "the meter follows the turn")
        #expect(agent?.lastTurnUsage?.totalTokens == 90229)
        #expect(agent?.costToDate["USD"] == 0.244)

        let page = try await core.transcript(.init(agentID: id))
        let usages = page.entries.filter { if case .usageRecorded = $0.kind { return true } else { return false } }
        #expect(usages.count == 1, "once per turn, at the end of it")
    }

    @Test func aRuntimeThatReportsNothingShowsNothing() async throws {
        let (locations, work) = try temporary()
        // Grok sends neither usage updates nor a usage block.
        let core = try core(FakeLauncher(), locations: locations)

        let id = try await core.start(.init(runtimeID: "grok", cwd: work, prompt: "go"))
        try await Task.sleep(for: .milliseconds(300))

        let agent = await core.agent(id)
        #expect(agent?.usage == nil)
        #expect(agent?.lastTurnUsage == nil)
        #expect(agent?.costToDate.isEmpty == true, "nothing is invented")
    }

    @Test func twoTurnsInTwoCurrenciesAreKeptApart() async throws {
        let (locations, work) = try temporary()
        var first = FakeACPAgent.Script()
        first.usage = ["totalTokens": 10, "cost": ["amount": 1.0, "currency": "USD"]]
        var second = FakeACPAgent.Script()
        second.usage = ["totalTokens": 10, "cost": ["amount": 2.0, "currency": "GBP"]]
        let launcher = FakeLauncher(script: first, then: [second])
        let core = try core(launcher, locations: locations)

        let id = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "one"))
        try await Task.sleep(for: .milliseconds(300))
        try await core.prompt(.init(agentID: id, text: "two"))
        try await Task.sleep(for: .milliseconds(300))

        let agent = await core.agent(id)
        #expect(agent?.costToDate["USD"] == 1.0)
        #expect(agent?.costToDate["GBP"] == 2.0)
    }
}
