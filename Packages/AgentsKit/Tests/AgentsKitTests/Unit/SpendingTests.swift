import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// The three cases that all look like "no money" from outside. Getting them wrong puts
/// a warning on a project where nothing has happened yet, or hides one on a project
/// whose runtime never said a price.
@Suite("What has been spent")
struct SpendingTests {
    private func agent(lastTurnUsage: TurnUsage? = nil,
                       costToDate: [String: Decimal] = [:]) -> Agent {
        Agent(runtimeID: "claude",
              cwd: URL(fileURLWithPath: "/tmp/work"),
              lastTurnUsage: lastTurnUsage,
              costToDate: costToDate)
    }

    @Test("an agent that has never finished a turn is not unmeasured")
    func neverRan() {
        #expect(agent().isUnmeasured == false)
    }

    @Test("an agent that ran and was priced is not unmeasured")
    func ranAndWasPriced() {
        let ran = agent(lastTurnUsage: TurnUsage(totalTokens: 10,
                                                 cost: Cost(amount: 1, currency: "USD")),
                        costToDate: ["USD": 1])
        #expect(ran.isUnmeasured == false)
    }

    @Test("an agent that ran and was never priced is unmeasured, not free")
    func ranAndWasNotPriced() {
        let ran = agent(lastTurnUsage: TurnUsage(totalTokens: 10))
        #expect(ran.isUnmeasured == true)
    }

    @Test("the three cases are told apart by the two fields alone")
    func exhaustive() {
        let cases: [(TurnUsage?, [String: Decimal], Bool)] = [
            (nil, [:], false),
            (TurnUsage(totalTokens: 1), ["USD": 0.5], false),
            (TurnUsage(totalTokens: 1), [:], true),
        ]
        for (usage, cost, expected) in cases {
            #expect(agent(lastTurnUsage: usage, costToDate: cost).isUnmeasured == expected)
        }
    }

    // MARK: The grand total

    private func summary(_ name: String,
                         _ costToDate: [String: Decimal],
                         archived: Bool = false,
                         exists: Bool = true,
                         unmeasured: Int = 0) -> DaemonAPI.ProjectSummary {
        let folder = URL(fileURLWithPath: "/tmp/\(name)")
        var project = Project(folder: folder)
        if archived { project.archivedAt = Date() }
        return DaemonAPI.ProjectSummary(project: project,
                                        name: name,
                                        exists: exists,
                                        lastActivityAt: Date(),
                                        counts: [:],
                                        costToDate: costToDate,
                                        unmeasuredAgents: unmeasured)
    }

    /// FR-011, and the first test written. It holds by construction today — the shares
    /// and the grand total are folded from the same array — and it exists because a
    /// later feature that starts filtering the project list before totalling would
    /// break it silently, losing money from the grand total with nothing to see.
    @Test("for every currency, the shares sum exactly to the grand total")
    func sharesAddUp() {
        let spending = Spending([
            summary("api", ["USD": 12.50, "GBP": 3]),
            summary("web", ["USD": 0.25]),
            summary("gone", ["GBP": 7], exists: false),
            summary("old", ["USD": 4], archived: true),
            summary("quiet", [:]),
        ])

        for currency in spending.currencies {
            let listed = spending.shares(in: currency).reduce(Decimal(0)) { $0 + $1.amount }
            #expect(listed == spending.grandTotal[currency],
                    "\(currency): the listed shares are the whole of the total")
        }
        #expect(spending.grandTotal["USD"] == 16.75)
        #expect(spending.grandTotal["GBP"] == 10)
    }

    @Test("shares come back largest first")
    func orderedWithinACurrency() {
        let spending = Spending([
            summary("small", ["USD": 1]),
            summary("large", ["USD": 100]),
            summary("middling", ["USD": 10]),
        ])

        #expect(spending.shares(in: "USD").map(\.name) == ["large", "middling", "small"])
    }

    @Test("two currencies order independently and no figure crosses between them")
    func currenciesDoNotMix() {
        let spending = Spending([
            summary("api", ["USD": 100, "GBP": 1]),
            summary("web", ["USD": 1, "GBP": 100]),
        ])

        #expect(spending.shares(in: "USD").map(\.name) == ["api", "web"])
        #expect(spending.shares(in: "GBP").map(\.name) == ["web", "api"])
        #expect(spending.shares(in: "USD").map(\.amount) == [100, 1])
        #expect(spending.currencies == ["GBP", "USD"], "code order, not an opinion")
    }

    @Test("a project that has spent nothing is in no share list")
    func nothingSpentIsNotListed() {
        let spending = Spending([
            summary("api", ["USD": 5]),
            summary("quiet", [:]),
        ])

        #expect(spending.shares(in: "USD").map(\.name) == ["api"])
    }

    @Test("archived projects and missing folders are listed with what they cost")
    func nothingIsFilteredOut() {
        let spending = Spending([
            summary("old", ["USD": 9], archived: true),
            summary("gone", ["USD": 3], exists: false),
        ])

        let shares = spending.shares(in: "USD")
        #expect(shares.map(\.name) == ["old", "gone"])
        #expect(shares.first?.isArchived == true)
        #expect(shares.last?.isArchived == false, "a folder that went was never put away")
        #expect(spending.grandTotal["USD"] == 12, "the money was still spent")
    }

    @Test("the unmeasured count is the sum across projects")
    func unmeasuredIsSummed() {
        let spending = Spending([
            summary("api", ["USD": 1], unmeasured: 2),
            summary("web", ["USD": 1], unmeasured: 1),
            summary("quiet", [:]),
        ])

        #expect(spending.unmeasuredAgents == 3)
    }

    @Test("nothing spent anywhere is empty rather than a row of zeroes")
    func nothingSpentAnywhere() {
        let spending = Spending([summary("api", [:]), summary("web", [:])])

        #expect(spending.isEmpty)
        #expect(spending.grandTotal.isEmpty)
        #expect(spending.currencies.isEmpty)
        #expect(spending.unmeasuredAgents == 0)
    }

    @Test("no projects at all is empty, not a crash")
    func noProjects() {
        #expect(Spending([]).isEmpty)
    }
}
