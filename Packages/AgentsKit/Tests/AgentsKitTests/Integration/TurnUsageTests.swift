import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

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
        // The meter and the turn's own total come from two different places — the
        // meter down the session's event stream, the total off the prompt's reply —
        // so neither one arriving says anything about the other, and the turn ending
        // says nothing about either.
        await eventually("both the meter and the turn's total arrived") {
            guard let agent = await core.agent(id) else { return false }
            return agent.usage?.used == 30360 && agent.lastTurnUsage?.totalTokens == 90229
                && agent.costToDate["USD"] == 0.244
        }
        @Sendable func usagesOnTheRecord() async -> Int {
            let page = try? await core.transcript(.init(agentID: id))
            return page?.entries.filter {
                if case .usageRecorded = $0.kind { return true } else { return false }
            }.count ?? 0
        }
        await eventually("the turn's usage reached the record") { await usagesOnTheRecord() == 1 }

        let agent = await core.agent(id)
        #expect(agent?.usage?.used == 30360, "the meter follows the turn")
        #expect(agent?.lastTurnUsage?.totalTokens == 90229)
        #expect(agent?.costToDate["USD"] == 0.244)
        #expect(await usagesOnTheRecord() == 1, "once per turn, at the end of it")
    }

    @Test func aRuntimeThatReportsNothingShowsNothing() async throws {
        let (locations, work) = try temporary()
        // Grok sends neither usage updates nor a usage block.
        let core = try core(FakeLauncher(), locations: locations)

        let id = try await core.start(.init(runtimeID: "grok", cwd: work, prompt: "go"))
        // An absence, so there is no value to wait for. The runtime being handed back
        // is the latest signal there is — it is the last thing `finishTurn` does, and
        // it ends the event stream any usage would have come down.
        await eventually("the runtime was handed back") { await core.live[id] == nil }

        let agent = await core.agent(id)
        #expect(agent?.usage == nil)
        #expect(agent?.lastTurnUsage == nil)
        #expect(agent?.costToDate.isEmpty == true, "nothing is invented")
    }

    /// The turn that crosses the ceiling is recorded whole, and only then does the
    /// agent stop. A transcript ending mid-tool-call is a bug in this feature, not an
    /// acceptable cost of enforcing a limit.
    @Test func theTurnThatCrossesTheLimitFinishesBeforeTheAgentStops() async throws {
        let (locations, work) = try temporary()
        try FileManager.default.createDirectory(at: locations.root, withIntermediateDirectories: true)
        try LimitStore(locations: locations).save(CostLimits(perAgent: Cost(amount: 1, currency: "USD")))

        var script = FakeACPAgent.Script()
        // One turn, well over the limit. A single long turn can pass a limit by a
        // wide margin before it ends, and the rule that a turn is never cut short
        // means it will. What must not happen is silence.
        script.usage = ["totalTokens": 10, "cost": ["amount": 2.5, "currency": "USD"]]
        script.updates = [["sessionUpdate": "agent_message_chunk",
                           "content": ["type": "text", "text": "the whole answer"]]]
        let core = try core(FakeLauncher(script: script), locations: locations)

        let id = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "go"))
        await eventually("the agent stopped for its limit") {
            await core.agent(id)?.endedReason == .costLimit
        }

        let agent = await core.agent(id)
        #expect(agent?.state == .stopped, "not finished: a limit is not a finish")
        #expect(agent?.costToDate["USD"] == 2.5,
                "the real figure, not one clamped to the limit — a clamped figure would be a lie")

        let page = try await core.transcript(.init(agentID: id))
        let said = page.entries.contains {
            if case .agentMessage(_, let text, _) = $0.kind { return text.contains("the whole answer") }
            return false
        }
        #expect(said, "the crossing turn is recorded in full before the agent stops")
        let usages = page.entries.filter {
            if case .usageRecorded = $0.kind { return true } else { return false }
        }
        #expect(usages.count == 1, "the turn's own usage still reached the record")
        let toldWhy = page.entries.contains {
            if case .runtimeNote(let note) = $0.kind { return note.contains("cost limit") || note.contains("limit you set") }
            return false
        }
        #expect(toldWhy, "the reader and the agent are both told which limit stopped it")
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
        // Handed back as well as finished: the second script is the second runtime's,
        // and a prompt sent while the first session is still open never starts one.
        await eventually("the first turn ended and its runtime went") {
            await core.agent(id)?.state == .finished
        }
        await eventually("the first runtime was handed back") { await core.live[id] == nil }
        try await core.prompt(.init(agentID: id, text: "two"))
        // Both at once rather than one then the other: which currency is banked first
        // is not something this test has an opinion about, and waiting on the wrong one
        // would be asserting an order nothing promises.
        await eventually("both turns were costed") {
            let costs = await core.agent(id)?.costToDate
            return costs?["USD"] == 1.0 && costs?["GBP"] == 2.0
        }

        let agent = await core.agent(id)
        #expect(agent?.costToDate["USD"] == 1.0)
        #expect(agent?.costToDate["GBP"] == 2.0)
    }
}
