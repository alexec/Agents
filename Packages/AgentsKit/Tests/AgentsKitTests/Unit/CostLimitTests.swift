import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// The rules that decide whether an agent may spend anything more, exhausted without
/// a daemon. Every one of them works by refusing, and a refusal leaves nothing behind
/// to look at — a cap that silently never fires looks exactly like one never reached.
@Suite("What the reader will allow")
struct CostLimitTests {
    /// An agent that has run at least one turn and settled, which is the only state
    /// in which any of these rules has anything to say. `hasRun` is what separates a
    /// runtime that answered without a price from one that has not answered yet.
    private func agent(spent: [String: Decimal] = [:],
                       ceiling: Cost? = nil,
                       lastTurn: TurnUsage? = nil,
                       hasRun: Bool = true) -> Agent {
        let born = Date(timeIntervalSince1970: 1_000_000)
        return Agent(runtimeID: "claude",
                     cwd: URL(fileURLWithPath: "/tmp"),
                     state: .finished,
                     createdAt: born,
                     lastActivityAt: hasRun ? born.addingTimeInterval(60) : born,
                     lastTurnUsage: lastTurn,
                     costToDate: spent,
                     costCeiling: ceiling)
    }

    private func usd(_ amount: Decimal) -> Cost { Cost(amount: amount, currency: "USD") }
    private func gbp(_ amount: Decimal) -> Cost { Cost(amount: amount, currency: "GBP") }

    // MARK: CostLimits on its own

    @Test("nothing set is nothing gated")
    func emptyIsTheStateBeforeAnybodySaidAnything() {
        #expect(CostLimits().isEmpty)
        #expect(!CostLimits(perAgent: usd(2)).isEmpty)
        #expect(!CostLimits(daily: usd(2)).isEmpty)
    }

    @Test("headroom is what is left in the limit's own currency")
    func headroomInACurrencyThatHasALimit() {
        let limits = CostLimits(perAgent: usd(2), daily: usd(10))
        #expect(limits.perAgentHeadroom(against: ["USD": 0.5]) == 1.5)
        #expect(limits.dailyHeadroom(against: ["USD": 4]) == 6)
    }

    @Test("no limit in that currency is no headroom to show")
    func headroomWithoutALimitIsNil() {
        let limits = CostLimits(perAgent: usd(2))
        #expect(limits.dailyHeadroom(against: ["USD": 4]) == nil)
        // Spend in a currency the limit is not in is counted and shown, never
        // compared: the USD limit has its full headroom despite the GBP spend.
        #expect(limits.perAgentHeadroom(against: ["GBP": 99]) == 2)
    }

    @Test("a limit of zero is a real limit, immediately reached")
    func zeroIsALimitAndNotAnAbsentOne() {
        let limits = CostLimits(perAgent: usd(0), daily: usd(0))
        #expect(!limits.isEmpty, "zero is something the reader said, not silence")
        #expect(limits.perAgentHeadroom(against: [:]) == 0, "zero headroom, not nil")
        #expect(limits.dailyHeadroom(against: [:]) == 0)
        #expect(limits.isDayLimitReached(spentToday: [:]), "nothing may run")
    }

    @Test("spending past a limit floors at zero rather than going negative")
    func headroomNeverGoesNegative() {
        let limits = CostLimits(perAgent: usd(1), daily: usd(1))
        #expect(limits.perAgentHeadroom(against: ["USD": 5]) == 0)
        #expect(limits.dailyHeadroom(against: ["USD": 5]) == 0)
    }

    @Test("the day's limit is reached, not exceeded")
    func theDayIsReachedAtTheLimitExactly() {
        let limits = CostLimits(daily: usd(10))
        #expect(!limits.isDayLimitReached(spentToday: ["USD": 9.99]))
        #expect(limits.isDayLimitReached(spentToday: ["USD": 10]))
        #expect(limits.isDayLimitReached(spentToday: ["USD": 10.01]))
        #expect(!limits.isDayLimitReached(spentToday: ["GBP": 999]), "another currency is not this one")
        #expect(!CostLimits().isDayLimitReached(spentToday: ["USD": 999]), "no limit, nothing reached")
    }

    // MARK: The four rules on an agent

    @Test("no limit anywhere is an agent nothing stops")
    func noCeilingMeansNotAtOne() {
        let a = agent(spent: ["USD": 99])
        #expect(a.ceiling(under: CostLimits()) == nil)
        #expect(!a.isAtCostLimit(under: CostLimits()))
        #expect(a.costHeadroom(under: CostLimits()) == nil, "nothing to show when uncapped")
    }

    @Test("the app-wide limit applies when the agent has no ceiling of its own")
    func theAppWideLimitIsTheDefault() {
        let limits = CostLimits(perAgent: usd(2))
        #expect(agent(spent: ["USD": 0.5]).ceiling(under: limits) == usd(2))
        #expect(!agent(spent: ["USD": 0.5]).isAtCostLimit(under: limits))
        #expect(agent(spent: ["USD": 0.5]).costHeadroom(under: limits) == 1.5)
        #expect(agent(spent: ["USD": 3]).isAtCostLimit(under: limits))
    }

    @Test("an agent's own ceiling wins, whether it raises or lowers")
    func theOverrideIsTheOnlyPrecedence() {
        let limits = CostLimits(perAgent: usd(2))
        let raised = agent(spent: ["USD": 3], ceiling: usd(10))
        #expect(raised.ceiling(under: limits) == usd(10))
        #expect(!raised.isAtCostLimit(under: limits), "let this one go on")
        #expect(raised.costHeadroom(under: limits) == 7)

        let lowered = agent(spent: ["USD": 1], ceiling: usd(0.5))
        #expect(lowered.ceiling(under: limits) == usd(0.5))
        #expect(lowered.isAtCostLimit(under: limits), "a tighter ceiling binds sooner")
        #expect(lowered.costHeadroom(under: limits) == 0)
    }

    @Test("exactly at the limit is at it — the spec says reaches, not exceeds")
    func exactlyAtTheLimitIsAtIt() {
        let limits = CostLimits(perAgent: usd(2))
        #expect(agent(spent: ["USD": 2]).isAtCostLimit(under: limits))
        #expect(!agent(spent: ["USD": 1.9999]).isAtCostLimit(under: limits))
    }

    @Test("an unmeasured agent is never capped and never shown a headroom")
    func unmeasuredIsNeverWithinALimit() {
        // A turn ended and the runtime said nothing at all about money. Two shapes
        // of that silence, and both are unmeasured: a usage block with no price in
        // it, and — the Grok case — no usage block at all.
        for unmeasured in [agent(lastTurn: TurnUsage(totalTokens: 100, cost: nil)),
                           agent(lastTurn: nil)] {
            #expect(unmeasured.costIsUnmeasured)
            for limits in [CostLimits(), CostLimits(perAgent: usd(2)),
                           CostLimits(perAgent: usd(0))] {
                #expect(!unmeasured.isAtCostLimit(under: limits),
                        "what cannot be measured cannot be capped")
                #expect(unmeasured.costHeadroom(under: limits) == nil,
                        "never presented as being within a limit")
            }
        }
    }

    @Test("an agent that has reported a cost is measured")
    func aCostReportedIsNotUnmeasured() {
        let measured = agent(spent: ["USD": 0.1],
                             lastTurn: TurnUsage(totalTokens: 100, cost: usd(0.1)))
        #expect(!measured.costIsUnmeasured)
        // Nor is one that has not run at all: silence before the first turn is not
        // the same fact as a runtime that answered without money, and a label that
        // appears before there is anything to label is one you stop trusting.
        #expect(!agent(hasRun: false).costIsUnmeasured)
    }

    @Test("a limit in a currency the agent has not spent in leaves it uncapped")
    func aLimitInAnotherCurrencyDoesNotBite() {
        let limits = CostLimits(perAgent: gbp(1))
        let a = agent(spent: ["USD": 500])
        #expect(!a.isAtCostLimit(under: limits), "nothing is converted and nothing is added")
        #expect(a.costHeadroom(under: limits) == 1, "the GBP limit is untouched")
    }

    @Test("lowering the limit is instantly true, with no write and no sweep")
    func loweringALimitNeedsNoMigration() {
        let a = agent(spent: ["USD": 5])
        #expect(!a.isAtCostLimit(under: CostLimits(perAgent: usd(10))))
        // The same agent value, unchanged, under a lower limit.
        #expect(a.isAtCostLimit(under: CostLimits(perAgent: usd(1))))
    }

    @Test("clearing a limit requires a null, never a zero")
    func clearingIsNotTheSameAsZero() {
        var limits = CostLimits(perAgent: usd(0))
        #expect(limits.isAtLeastOneLimitSet, "zero stops everything")
        // Reached by the very first penny, which is what "nothing may run" means
        // for an agent whose runtime does report a price.
        #expect(agent(spent: ["USD": 0.0001]).isAtCostLimit(under: limits))
        #expect(agent(spent: ["USD": 0]).isAtCostLimit(under: limits),
                "and by a turn priced at zero, because zero reaches zero")
        limits.perAgent = nil
        #expect(!limits.isAtLeastOneLimitSet)
        #expect(!agent(spent: ["USD": 99]).isAtCostLimit(under: limits))
    }

    /// Where the spec's two strictest rules meet. A zero limit says *nothing may
    /// run*; FR-013 says what cannot be measured cannot be capped. FR-013 wins for
    /// the per-agent limit, because capping on a figure that was never reported is
    /// capping on a guess — and the app refuses to guess about money anywhere else.
    ///
    /// Nothing is lost by this: a zero *daily* limit still refuses every new agent
    /// outright, whatever runtime it would have used, because that gate is about the
    /// day's total and not about any one agent's figure.
    @Test("a zero limit still cannot cap an agent whose runtime reports no price")
    func whatCannotBeMeasuredIsNotCappedEvenAtZero() {
        let unmeasured = agent(lastTurn: nil)
        #expect(unmeasured.costIsUnmeasured)
        #expect(!unmeasured.isAtCostLimit(under: CostLimits(perAgent: usd(0))))
        #expect(unmeasured.costHeadroom(under: CostLimits(perAgent: usd(0))) == nil,
                "and it is never shown as being within one")
        // The day's limit is not about any one agent, so zero there stops everything.
        #expect(CostLimits(daily: usd(0)).isDayLimitReached(spentToday: [:]))
    }

    @Test("a limit is an ending in its own right, and never a finish")
    func theEndingIsItsOwnThing() {
        #expect(EndedReason.costLimit.isFinish == false,
                "the app decided it had spent enough; it did not say what it had to say")
        #expect(EndedReason.costLimit.summary == "Reached its cost limit")
        // Distinct from every other ending, so it is distinguishable at a glance
        // from one that finished, one that crashed, and one the reader stopped.
        let others = EndedReason.allCases.filter { $0 != .costLimit }
        #expect(!others.map(\.summary).contains("Reached its cost limit"))
        // Nothing on the wire ever spells this: it is not a protocol stop reason.
        #expect(EndedReason(stopReason: "cost_limit") == nil)
        #expect(EndedReason(stopReason: "costLimit") == nil)
    }

    @Test("with both limits cleared the feature is invisible")
    func nothingSetIsTheAppAsItWasBefore() {
        let off = CostLimits()
        #expect(off.isEmpty)
        for spent in [[:], ["USD": 9_999], ["GBP": 1]] as [[String: Decimal]] {
            let a = agent(spent: spent)
            #expect(!a.isAtCostLimit(under: off), "nothing is stopped")
            #expect(a.costHeadroom(under: off) == nil, "and nothing new is shown")
            #expect(a.ceiling(under: off) == nil)
            #expect(!off.isDayLimitReached(spentToday: spent), "nothing is refused")
        }
    }

    @Test("the limits round-trip through JSON with zero intact")
    func limitsSurviveTheFile() throws {
        let original = CostLimits(perAgent: usd(0), daily: gbp(2.5))
        let data = try JSONEncoder().encode(original)
        let read = try JSONDecoder().decode(CostLimits.self, from: data)
        #expect(read == original)
        #expect(read.perAgent?.amount == 0, "zero did not become nil on the way")

        let empty = try JSONDecoder().decode(CostLimits.self, from: Data("{}".utf8))
        #expect(empty.isEmpty)
    }
}

private extension CostLimits {
    /// Reads better in a test than `!isEmpty` where the point is that something is set.
    var isAtLeastOneLimitSet: Bool { !isEmpty }
}
