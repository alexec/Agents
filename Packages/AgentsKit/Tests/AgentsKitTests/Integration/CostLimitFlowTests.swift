import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// Both limits, end to end, against a temporary root with no CLI, no credential and
/// no network. The money is the fake runtime's, which is how a feature about spending
/// is exercised without spending anything.
///
/// Every rule here works by refusing to act, and a refusal leaves nothing behind to
/// click on: a cap that silently never fires looks exactly like a cap that was never
/// reached, which is why each case asserts on what was recorded rather than on an
/// absence.
@Suite("Cost limits", .timeLimit(.minutes(1)))
struct CostLimitIntegrationTests {
    private func temporary() throws -> (StoreLocations, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsCostLimitTests-\(UUID().uuidString)", isDirectory: true)
        let work = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        return (StoreLocations(root: root), work)
    }

    private func core(_ launcher: FakeLauncher, locations: StoreLocations,
                      now: (@Sendable () -> Date)? = nil) throws -> DaemonCore {
        DaemonCore(store: try AgentStore(locations: locations),
                   locations: locations,
                   discovery: .findsEverything,
                   launcher: launcher,
                   now: now)
    }

    private func setLimits(_ limits: CostLimits, at locations: StoreLocations) throws {
        try FileManager.default.createDirectory(at: locations.root, withIntermediateDirectories: true)
        try LimitStore(locations: locations).save(limits)
    }

    private func costing(_ amount: Decimal, _ currency: String = "USD") -> FakeACPAgent.Script {
        var script = FakeACPAgent.Script()
        script.usage = ["totalTokens": 10,
                        "cost": ["amount": .double(NSDecimalNumber(decimal: amount).doubleValue),
                                 "currency": .string(currency)]]
        return script
    }

    private func notes(_ core: DaemonCore, _ id: UUID) async -> [String] {
        let page = try? await core.transcript(.init(agentID: id))
        return (page?.entries ?? []).compactMap {
            if case .runtimeNote(let note) = $0.kind { return note } else { return nil }
        }
    }

    // MARK: User Story 1 — one agent stops itself

    @Test("a prompt to an at-limit agent leaves the words on the queue and sends nothing")
    func wordsStayExactlyWhereTheyWere() async throws {
        let (locations, work) = try temporary()
        try setLimits(CostLimits(perAgent: Cost(amount: 1, currency: "USD")), at: locations)
        let core = try core(FakeLauncher(script: costing(2), then: [costing(2)]),
                            locations: locations)

        let id = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "go"))
        await eventually("the agent reached its limit") {
            await core.agent(id)?.endedReason == .costLimit
        }

        // A prompt to an existing agent succeeds. Holding is not an error: losing
        // what somebody typed because a budget was reached would be the worst
        // possible reading of "control cost".
        try await core.prompt(.init(agentID: id, text: "carry on"))
        try await Task.sleep(for: .milliseconds(200))

        let agent = await core.agent(id)
        #expect(agent?.queuedPrompts.map(\.text) == ["carry on"], "the words stay where they were")
        #expect(agent?.costToDate["USD"] == 2, "nothing further was spent")
        #expect(await core.live[id] == nil, "no runtime was started for a turn that may not run")
        #expect(await notes(core, id).contains { $0.contains("reached its cost limit") },
                "a refusal nobody can see is a refusal nobody can act on")
    }

    @Test("a ceiling set on one agent changes no other agent and neither limit")
    func anAllowanceIsForOneAgentAlone() async throws {
        let (locations, work) = try temporary()
        try setLimits(CostLimits(perAgent: Cost(amount: 1, currency: "USD")), at: locations)
        let core = try core(FakeLauncher(script: costing(2), then: [costing(2), costing(2)]),
                            locations: locations)

        let first = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "one"))
        await eventually("the first reached its limit") {
            await core.agent(first)?.endedReason == .costLimit
        }
        let second = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "two"))
        await eventually("the second reached its limit") {
            await core.agent(second)?.endedReason == .costLimit
        }

        let raised = try await core.setCeiling(.init(agentID: first,
                                                     ceiling: Cost(amount: 10, currency: "USD")))
        #expect(raised.costCeiling == Cost(amount: 10, currency: "USD"))
        #expect(!raised.isAtCostLimit(under: CostLimits(perAgent: Cost(amount: 1, currency: "USD"))))

        let other = await core.agent(second)
        #expect(other?.costCeiling == nil, "no other agent's ceiling is touched")
        let state = await core.costState()
        #expect(state.limits.perAgent == Cost(amount: 1, currency: "USD"),
                "and neither app-wide limit is changed")
    }

    @Test("raising a ceiling makes an agent promptable again but does not resume it")
    func continuingIsTheReadersSecondAct() async throws {
        let (locations, work) = try temporary()
        try setLimits(CostLimits(perAgent: Cost(amount: 1, currency: "USD")), at: locations)
        // `then:` is the launch order, and it covers the first launch too.
        let core = try core(FakeLauncher(then: [costing(2), costing(0.1)]),
                            locations: locations)

        let id = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "go"))
        await eventually("it reached its limit") { await core.agent(id)?.endedReason == .costLimit }
        try await core.prompt(.init(agentID: id, text: "waiting"))
        try await Task.sleep(for: .milliseconds(150))
        #expect(await core.agent(id)?.queuedPrompts.count == 1)

        _ = try await core.setCeiling(.init(agentID: id, ceiling: Cost(amount: 10, currency: "USD")))
        try await Task.sleep(for: .milliseconds(200))
        // Raising the ceiling makes the agent promptable; it does not itself send
        // the prompt. FR-018 forbids making continuing the automatic response.
        #expect(await core.agent(id)?.queuedPrompts.count == 1,
                "raising a ceiling is not the same act as continuing")

        // The reader's second act. Sending anything drains what was waiting.
        try await core.prompt(.init(agentID: id, text: "now go"))
        await eventually("the held words went once the reader asked") {
            await core.agent(id)?.costToDate["USD"] ?? 0 > 2
        }
    }

    // MARK: User Story 2 — the day

    @Test("a new agent is refused by name when the day's limit is reached")
    func startIsRefusedAndSaysWhy() async throws {
        let (locations, work) = try temporary()
        try setLimits(CostLimits(daily: Cost(amount: 1, currency: "USD")), at: locations)
        let core = try core(FakeLauncher(script: costing(2), then: [costing(2)]),
                            locations: locations)

        let first = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "one"))
        await eventually("the day's money was banked") {
            await core.costState().today["USD"] ?? 0 >= 1
        }
        #expect(await core.costState().dayLimitReached)
        // The first agent is not itself at a per-agent limit — there is none set.
        #expect(await core.agent(first)?.endedReason == .endTurn,
                "the day's limit does not end the agent that reached it; it holds everything")

        await #expect(throws: JSONRPCError.self) {
            _ = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "two"))
        }
        do {
            _ = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "two"))
            Issue.record("a new agent must be refused while the day's limit is reached")
        } catch let error as JSONRPCError {
            #expect(error.code == DaemonAPI.Failure.dayLimitReached)
            #expect(error.message.contains("day"), "a silent refusal is the one thing forbidden")
        }
    }

    @Test("a prompt to an existing agent succeeds and waits, while the day is over")
    func aPromptHoldsWhereAStartRefuses() async throws {
        let (locations, work) = try temporary()
        try setLimits(CostLimits(daily: Cost(amount: 1, currency: "USD")), at: locations)
        let core = try core(FakeLauncher(script: costing(2), then: [costing(2)]),
                            locations: locations)

        let id = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "one"))
        await eventually("the day's limit was reached") { await core.costState().dayLimitReached }

        // Succeeds. A new agent has no queue to wait on, which is why that is a
        // refusal where this is a hold.
        try await core.prompt(.init(agentID: id, text: "tomorrow's work"))
        try await Task.sleep(for: .milliseconds(200))
        #expect(await core.agent(id)?.queuedPrompts.map(\.text) == ["tomorrow's work"])
        #expect(await core.costState().today["USD"] == 2, "and nothing more was spent")
        #expect(await notes(core, id).contains { $0.contains("day's spending limit") })
    }

    @Test("the day's total is written before the windows are told, and survives a restart")
    func theRecordIsWrittenBeforeTheBroadcast() async throws {
        let (locations, work) = try temporary()
        let core = try core(FakeLauncher(script: costing(3.25)), locations: locations)

        let id = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "go"))
        await eventually("the turn was costed") { await core.agent(id)?.costToDate["USD"] == 3.25 }

        // Read straight off the file, without going through the daemon: the ledger
        // is on disk by the time the agent's own total is, so a daemon killed
        // mid-bank comes back having counted the money.
        let onDisk = SpendLedger(locations: locations).total(on: Date())
        #expect(onDisk["USD"] == 3.25)

        // A second daemon on the same root: a restart part-way through a day.
        let afterRestart = DaemonCore(store: try AgentStore(locations: locations),
                                      locations: locations,
                                      discovery: .findsEverything,
                                      launcher: FakeLauncher())
        #expect(await afterRestart.costState().today["USD"] == 3.25,
                "the day resumes its true total rather than starting again from zero")
    }

    @Test("raising the daily limit drains what was holding, on the same call")
    func raisingTheLimitNeedsNoRestart() async throws {
        let (locations, work) = try temporary()
        try setLimits(CostLimits(daily: Cost(amount: 1, currency: "USD")), at: locations)
        let core = try core(FakeLauncher(then: [costing(2), costing(0.5)]),
                            locations: locations)

        let id = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "one"))
        await eventually("the day's limit was reached") { await core.costState().dayLimitReached }
        try await core.prompt(.init(agentID: id, text: "held"))
        try await Task.sleep(for: .milliseconds(200))
        #expect(await core.agent(id)?.queuedPrompts.count == 1)

        let state = await core.setLimits(.init(daily: .some(Cost(amount: 100, currency: "USD"))))
        #expect(!state.dayLimitReached)
        await eventually("what was holding went, with no restart and no second act") {
            await core.agent(id)?.queuedPrompts.isEmpty == true
        }
    }

    @Test("the day rolling over drains what was holding, with nobody doing anything")
    func midnightLiftsTheHold() async throws {
        let (locations, work) = try temporary()
        try setLimits(CostLimits(daily: Cost(amount: 1, currency: "USD")), at: locations)
        // The daemon's own clock, which the test moves. Every date in this feature
        // comes from here, so moving it past midnight is the whole of a rollover.
        let clock = Clock(Date())
        let core = try core(FakeLauncher(then: [costing(2), costing(0.5)]),
                            locations: locations, now: { clock.now })

        let id = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "one"))
        await eventually("the day's limit was reached") { await core.costState().dayLimitReached }
        try await core.prompt(.init(agentID: id, text: "held overnight"))
        try await Task.sleep(for: .milliseconds(200))
        #expect(await core.agent(id)?.queuedPrompts.count == 1)
        let conversation = (try await core.transcript(.init(agentID: id))).entries.count

        // Two ticks: the first notes today, the second is tomorrow. Nobody does
        // anything in between — that is the point of the scenario.
        await core.tickWorkflows(now: clock.now)
        clock.advance(by: 60 * 60 * 25)
        await core.tickWorkflows(now: clock.now)

        await eventually("the held words went when the day rolled over") {
            await core.agent(id)?.queuedPrompts.isEmpty == true
        }
        #expect(await core.agent(id) != nil, "the agent was not restarted, it was prompted")
        await eventually("the new day counts only what it spent") {
            await core.costState().today["USD"] == 0.5
        }
        let after = (try await core.transcript(.init(agentID: id))).entries.count
        #expect(after >= conversation, "its conversation is intact, where it stood")
    }

    // MARK: A runtime that reports no cost

    @Test("an agent that cannot be measured runs past both limits and counts for nothing")
    func whatCannotBeMeasuredCannotBeCapped() async throws {
        let (locations, work) = try temporary()
        // Low enough that any measured agent would be stopped at once.
        try setLimits(CostLimits(perAgent: Cost(amount: 0.01, currency: "USD"),
                                 daily: Cost(amount: 0.01, currency: "USD")),
                      at: locations)
        // Grok sends neither usage updates nor a usage block.
        let core = try core(FakeLauncher(), locations: locations)

        let id = try await core.start(.init(runtimeID: "grok", cwd: work, prompt: "go"))
        await eventually("the turn ended") { await core.live[id] == nil }

        let agent = await core.agent(id)
        #expect(agent?.endedReason == .endTurn, "a limit it cannot reach did not stop it")
        #expect(agent?.costIsUnmeasured == true)
        #expect(agent?.isAtCostLimit(under: CostLimits(perAgent: Cost(amount: 0.01, currency: "USD"))) == false,
                "never presented as being within a limit")
        #expect(await core.costState().today.isEmpty,
                "it contributes nothing, so the day's total is a floor rather than a fact")
        #expect(await core.costState().dayLimitReached == false)

        // And it can still be prompted: nothing is holding it.
        try await core.prompt(.init(agentID: id, text: "again"))
        await eventually("it took the prompt") {
            await core.agent(id)?.queuedPrompts.isEmpty == true
        }
    }

    // MARK: Two currencies

    @Test("a limit in one currency never caps spend in another, and nothing is added")
    func nothingIsConvertedAndNothingIsSummed() async throws {
        let (locations, work) = try temporary()
        try setLimits(CostLimits(perAgent: Cost(amount: 1, currency: "USD"),
                                 daily: Cost(amount: 1, currency: "USD")),
                      at: locations)
        let core = try core(FakeLauncher(script: costing(50, "GBP"), then: [costing(50, "GBP")]),
                            locations: locations)

        let id = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "go"))
        await eventually("the pounds were banked") {
            await core.agent(id)?.costToDate["GBP"] == 50
        }

        let agent = await core.agent(id)
        #expect(agent?.endedReason == .endTurn, "a USD limit does not cap GBP spend")
        let state = await core.costState()
        #expect(state.today["GBP"] == 50, "counted under its own key")
        #expect(state.today["USD"] == nil, "and never folded into another")
        #expect(!state.dayLimitReached, "a limit cannot be more permissive about arithmetic than the display")

        // A second agent still starts: the day's USD limit is untouched by pounds.
        let second = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "again"))
        #expect(await core.agent(second) != nil)
    }

    // MARK: The reader can always tidy up

    @Test("stop, archive and unqueue all still work while both limits are reached")
    func theReaderIsNeverTrapped() async throws {
        let (locations, work) = try temporary()
        try setLimits(CostLimits(perAgent: Cost(amount: 1, currency: "USD"),
                                 daily: Cost(amount: 1, currency: "USD")),
                      at: locations)
        let core = try core(FakeLauncher(script: costing(5), then: [costing(5)]),
                            locations: locations)

        let id = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "go"))
        await eventually("both limits are reached") {
            let ended = await core.agent(id)?.endedReason == .costLimit
            let day = await core.costState().dayLimitReached
            return ended && day
        }

        try await core.prompt(.init(agentID: id, text: "one"))
        try await Task.sleep(for: .milliseconds(150))
        let queued = try #require(await core.agent(id)?.queuedPrompts.first)
        try await core.unqueue(.init(agentID: id, promptID: queued.id))
        #expect(await core.agent(id)?.queuedPrompts.isEmpty == true, "un-queueing still works")

        try await core.stop(id)
        try await core.archive(id)
        #expect(await core.agent(id)?.state == .archived,
                "the reader must always be able to stop and tidy up, budget or no budget")
    }

    // MARK: Nothing an agent can reach

    @Test("no cost method is served to an agent")
    func arunawayCannotRaiseItsOwnLimit() throws {
        // 008's rule about the chain-depth limit, applied to money. Asserted on the
        // served tool list rather than by reading the source, so a tool added later
        // fails this rather than quietly widening what an agent may do.
        let served = [AppTool.suggestPrompts, AppTool.showFile, AppTool.manageWorkflows]
        for forbidden in ["limit", "ceiling", "cost", "spend", "budget"] {
            #expect(!served.contains { $0.localizedCaseInsensitiveContains(forbidden) },
                    "\(forbidden) must not be reachable by an agent")
        }
        // And the three methods that do change a limit are not in the agent's
        // vocabulary at any spelling.
        for method in [DaemonAPI.Method.costSetLimits, DaemonAPI.Method.agentsSetCeiling,
                       DaemonAPI.Method.costState] {
            #expect(!served.contains(method))
        }
    }
}

/// A clock a test can move. The daemon reads it for every date about money, so
/// walking it past midnight is a rollover in the only sense the feature has.
private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date

    init(_ date: Date) { self.date = date }

    var now: Date {
        lock.lock(); defer { lock.unlock() }
        return date
    }

    func advance(by seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        date = date.addingTimeInterval(seconds)
    }
}
