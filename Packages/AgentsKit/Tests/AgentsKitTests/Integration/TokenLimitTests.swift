import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// Token limits beside the money ones (#838), for the runtimes that report tokens and
/// no price: whichever limit is reached first stops the agent, or the day.
@Suite("Token limits", .timeLimit(.minutes(1)))
struct TokenLimitTests {
    private func temporary() throws -> (StoreLocations, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsTokenLimitTests-\(UUID().uuidString)", isDirectory: true)
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

    private func setLimits(_ limits: CostLimits, at locations: StoreLocations) throws {
        try FileManager.default.createDirectory(at: locations.root, withIntermediateDirectories: true)
        try LimitStore(locations: locations).save(limits)
    }

    /// A turn that reports tokens and no price, as Gemini's does.
    private func using(input: Int, output: Int) -> FakeACPAgent.Script {
        var script = FakeACPAgent.Script()
        script.usage = ["totalTokens": .int(input + output),
                        "inputTokens": .int(input),
                        "outputTokens": .int(output)]
        return script
    }

    private func agent(tokens: Int, ceiling: Int? = nil, lastTurn: TurnUsage? = nil) -> Agent {
        let born = Date(timeIntervalSince1970: 1_000_000)
        return Agent(runtimeID: "gemini", cwd: URL(fileURLWithPath: "/tmp"), state: .finished,
                     createdAt: born, lastActivityAt: born.addingTimeInterval(60),
                     lastTurnUsage: lastTurn, tokensToDate: tokens, tokenCeiling: ceiling)
    }

    // MARK: The rules on their own

    @Test("a cache read is not counted, wherever the runtime puts it")
    func cacheReadsAreLeftOut() {
        // Beside the input, as Claude, Codex and OpenCode report it.
        #expect(TurnUsage(totalTokens: 1_300, inputTokens: 200, outputTokens: 100,
                          cachedReadTokens: 1_000).limitTokens == 300)
        // Inside the input, as Copilot reports it: the total is input plus output.
        #expect(TurnUsage(totalTokens: 1_300, inputTokens: 1_200, outputTokens: 100,
                          cachedReadTokens: 1_000).limitTokens == 300)
        // A cache write is new input.
        #expect(TurnUsage(totalTokens: 350, inputTokens: 200, outputTokens: 100,
                          cachedWriteTokens: 50).limitTokens == 350)
    }

    @Test("an agent at its token ceiling is at its limit, and one with no tokens never is")
    func theAgentRules() {
        let limits = CostLimits(perAgentTokens: 1_000)
        #expect(agent(tokens: 1_000, lastTurn: TurnUsage(totalTokens: 10, inputTokens: 10)).isAtCostLimit(under: limits))
        #expect(!agent(tokens: 999, lastTurn: TurnUsage(totalTokens: 10, inputTokens: 10)).isAtCostLimit(under: limits))
        #expect(agent(tokens: 400, lastTurn: TurnUsage(totalTokens: 10, inputTokens: 10))
            .tokenHeadroom(under: limits) == 600)
        // Its own ceiling wins over the app-wide one.
        #expect(!agent(tokens: 1_500, ceiling: 2_000, lastTurn: TurnUsage(totalTokens: 10, inputTokens: 10))
            .isAtCostLimit(under: limits))
        // Codex reports no tokens: no token limit applies, and the app says so.
        let codex = agent(tokens: 0)
        #expect(codex.tokensAreUnmeasured)
        #expect(!codex.isAtCostLimit(under: CostLimits(perAgentTokens: 0)))
        #expect(codex.tokenHeadroom(under: limits) == nil)
    }

    @Test("going on is one more step of the token ceiling")
    func goingOn() {
        let limits = CostLimits(perAgentTokens: 1_000)
        #expect(agent(tokens: 1_200).tokenCeilingToGoOn(under: limits) == 2_200)
        #expect(agent(tokens: 1_200).tokenCeilingToGoOn(under: CostLimits()) == nil)
    }

    @Test("the day's token limit is reached on the same word as the money")
    func theDayRule() {
        let limits = CostLimits(dailyTokens: 5_000)
        #expect(!limits.isDayLimitReached(spentToday: [:], tokensToday: 4_999))
        #expect(limits.isDayLimitReached(spentToday: [:], tokensToday: 5_000))
        #expect(limits.dailyTokenHeadroom(against: 6_000) == 0)
        #expect(!limits.isEmpty)
    }

    @Test("a limits file from before token limits reads as no token limit")
    func oldFilesRead() throws {
        let old = #"{"perAgent":{"amount":2,"currency":"USD"}}"#
        let limits = try JSONDecoder().decode(CostLimits.self, from: Data(old.utf8))
        #expect(limits.perAgentTokens == nil && limits.dailyTokens == nil)
        #expect(limits.perAgent?.amount == 2)
    }

    // MARK: End to end

    @Test("an agent that reports only tokens stops at its token limit and says so")
    func anAgentStopsAtItsTokens() async throws {
        let (locations, work) = try temporary()
        try setLimits(CostLimits(perAgentTokens: 250), at: locations)
        let core = try core(FakeLauncher(script: using(input: 200, output: 100),
                                         then: [using(input: 200, output: 100)]),
                            locations: locations)

        let id = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "go"))
        await eventually("the agent reached its token limit") {
            await core.agent(id)?.endedReason == .costLimit
        }
        #expect(await core.agent(id)?.tokensToDate == 300)
        #expect(await core.costState().tokensToday == 300, "the day counts it too")
        let page = try await core.transcript(.init(agentID: id))
        let notes = page.entries.compactMap { entry -> String? in
            if case .runtimeNote(let note) = entry.kind { return note } else { return nil }
        }
        #expect(notes.contains { $0.contains("300 tokens") }, "it says which limit stopped it")

        // Letting it go on raises its own token ceiling, and nothing else.
        let agent = try #require(await core.agent(id))
        let limits = CostLimits(perAgentTokens: 250)
        _ = try await core.setCeiling(.init(agentID: id, ceiling: nil,
                                            tokenCeiling: agent.tokenCeilingToGoOn(under: limits)))
        #expect(await core.agent(id)?.isAtCostLimit(under: limits) == false)
        #expect(await core.costState().limits.perAgentTokens == 250)
    }

    @Test("a new agent is refused when the day's tokens reach the day's token limit")
    func theDayRefusesANewAgent() async throws {
        let (locations, work) = try temporary()
        try setLimits(CostLimits(dailyTokens: 100), at: locations)
        let core = try core(FakeLauncher(script: using(input: 80, output: 40),
                                         then: [using(input: 80, output: 40)]),
                            locations: locations)

        _ = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "one"))
        await eventually("the day's tokens were counted") {
            await core.costState().tokensToday >= 100
        }
        #expect(await core.costState().dayLimitReached)
        do {
            _ = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "two"))
            Issue.record("a new agent must be refused while the day's token limit is reached")
        } catch let error as JSONRPCError {
            #expect(error.code == DaemonAPI.Failure.dayLimitReached)
            #expect(error.message.contains("tokens"))
        }

        // Raising it lets work start again, with no restart.
        _ = try await core.setLimits(.init(dailyTokens: .some(10_000)))
        #expect(await core.costState().dayLimitReached == false)
        #expect(await core.costState().dayTokenHeadroom == 10_000 - 120)
    }

    @Test("the day's tokens survive a restart, in the same file as the money")
    func theDayIsKept() async throws {
        let (locations, _) = try temporary()
        let ledger = SpendLedger(locations: locations)
        try FileManager.default.createDirectory(at: locations.root, withIntermediateDirectories: true)
        let now = Date()
        ledger.record(tokens: 1_234, on: now)
        try ledger.flush()
        #expect(SpendLedger(locations: locations).tokens(on: now) == 1_234)
    }
}
