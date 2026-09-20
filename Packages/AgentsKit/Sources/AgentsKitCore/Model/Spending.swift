import Foundation

/// What a reader is owed about all of the work, rather than about one agent.
///
/// `Usage` and `Cost` are what a runtime reported about a single agent. Everything in
/// this file is about the whole: what a folder has cost, what all of them have cost,
/// and which part of that figure the app could not measure. Nothing here is stored.
/// Every value is derived on demand from `Agent.costToDate`, which is already written
/// to disk on every change, so there is no second copy that could disagree with the
/// records and nothing to migrate.

public extension Agent {
    /// Whether this agent ran and the runtime would not say what it cost.
    ///
    /// Computed, and must never become stored state — the same rule as
    /// `Usage.isCloseToFull` and `AgentGroup(for:)`. It is also retroactively correct
    /// for every record already on disk, because `finishTurn` has always set
    /// `lastTurnUsage` whenever the runtime reported usage at all and has only ever
    /// added to `costToDate` when a price came with it.
    ///
    /// Three cases, all of which look like "no money" from outside:
    ///
    /// | Case | `lastTurnUsage` | `costToDate` | `usage.cost` | `isUnmeasured` |
    /// |---|---|---|---|---|
    /// | Started, never finished a turn | nil | empty | — | false — nothing has happened yet |
    /// | Ran, runtime reported a price | set | non-empty | — | false — measured |
    /// | Ran, priced only mid-turn | set | empty | set | false — measured, and banked from there |
    /// | Ran, runtime reported no price | set | empty | nil | **true** — unmeasurable, not free |
    var isUnmeasured: Bool {
        lastTurnUsage != nil && costToDate.isEmpty && usage?.cost == nil
    }
}

/// What all of the work has cost, and where it went.
///
/// A pure fold over the project summaries a window already holds, so the grand total
/// and the shares beneath it cannot disagree: both come from the same array in the same
/// render, and neither needs a fetch of its own.
///
/// Nothing here converts or adds across currencies. `grandTotal` is a dictionary, never
/// a number — two currencies cannot be ranked without a rate the app deliberately does
/// not have, which is why the shares are ordered *within* a currency and never across.
public struct Spending: Sendable {
    /// Every project's spend, added per currency. Empty when nothing has ever been
    /// spent anywhere.
    public let grandTotal: [String: Decimal]
    /// The currency codes anything has been spent in, in code order. Empty, one, or
    /// rarely more.
    public let currencies: [String]
    /// How many agents anywhere finished a turn the runtime would not price. Non-zero
    /// means every figure here is a floor rather than the whole.
    public let unmeasuredAgents: Int

    private let summaries: [DaemonAPI.ProjectSummary]

    public init(_ summaries: [DaemonAPI.ProjectSummary]) {
        self.summaries = summaries
        var total: [String: Decimal] = [:]
        var unmeasured = 0
        for summary in summaries {
            for (currency, amount) in summary.costToDate {
                total[currency, default: 0] += amount
            }
            unmeasured += summary.unmeasuredAgents
        }
        self.grandTotal = total
        self.currencies = total.keys.sorted()
        self.unmeasuredAgents = unmeasured
    }

    /// Nothing has ever been spent, in any currency. The page says so in a sentence
    /// rather than drawing a row of zeroes.
    public var isEmpty: Bool { grandTotal.isEmpty }

    /// Every project with spend in this currency, largest first.
    ///
    /// Nothing filters: an archived project and a project whose folder has gone are
    /// both listed with what they cost, because the money was still spent. A project
    /// that has spent nothing in this currency is not listed and contributes nothing,
    /// which is what makes the listed shares sum exactly to `grandTotal`.
    public func shares(in currency: String) -> [Share] {
        summaries
            .compactMap { summary in
                guard let amount = summary.costToDate[currency] else { return nil }
                return Share(folder: summary.folder,
                             name: summary.name,
                             isArchived: summary.project.isArchived,
                             amount: amount)
            }
            .sorted { first, second in
                if first.amount != second.amount { return first.amount > second.amount }
                // A tie is broken by name so two renders of the same figures cannot
                // swap two rows over between them.
                return first.name < second.name
            }
    }

    /// One project's line on the page, in the currency of the section it is in.
    public struct Share: Sendable, Identifiable, Hashable {
        public let folder: URL
        public let name: String
        public let isArchived: Bool
        public let amount: Decimal

        public var id: URL { folder }

        public init(folder: URL, name: String, isArchived: Bool, amount: Decimal) {
            self.folder = folder
            self.name = name
            self.isArchived = isArchived
            self.amount = amount
        }
    }
}
