import Foundation

/// How full an agent's context is, at a point in a turn.
///
/// The runtimes send this several times a turn and 001 discarded every one. A full
/// context is the most common reason an agent starts behaving oddly and there is no
/// other way to see it coming.
public struct Usage: Codable, Hashable, Sendable {
    public var used: Int
    public var size: Int
    public var cost: Cost?
    public var at: Date
    /// Claude's plan window, when this update carried it (052, R2). Kept in memory only
    /// and out of `CodingKeys`: it is the allowance's state, not the agent's, and is
    /// written where allowances are kept rather than into every `agent.json`.
    public var rateLimit: RateLimitInfo?

    public init(used: Int, size: Int, cost: Cost? = nil, at: Date = Date()) {
        self.used = used
        self.size = size
        self.cost = cost
        self.at = at
    }

    private enum CodingKeys: String, CodingKey { case used, size, cost, at }

    /// Nil when the runtime did not say how big the window is, which is how the meter
    /// knows to stay hidden rather than draw a zero.
    public var fraction: Double? {
        guard size > 0 else { return nil }
        return min(1, Double(used) / Double(size))
    }

    /// One number, in the kit, with a test. Not a view's idea of "nearly".
    public static let closeToFull = 0.85

    public var isCloseToFull: Bool { (fraction ?? 0) >= Self.closeToFull }
}

/// What one turn actually consumed, as reported when the turn ends. A different fact
/// from `Usage`, which is how full the window is at a moment.
public struct TurnUsage: Codable, Hashable, Sendable {
    public var totalTokens: Int
    public var inputTokens: Int
    public var outputTokens: Int
    public var thoughtTokens: Int?
    public var cachedReadTokens: Int?
    public var cachedWriteTokens: Int?
    public var cost: Cost?

    public init(totalTokens: Int = 0, inputTokens: Int = 0, outputTokens: Int = 0,
                thoughtTokens: Int? = nil, cachedReadTokens: Int? = nil,
                cachedWriteTokens: Int? = nil, cost: Cost? = nil) {
        self.totalTokens = totalTokens
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.thoughtTokens = thoughtTokens
        self.cachedReadTokens = cachedReadTokens
        self.cachedWriteTokens = cachedWriteTokens
        self.cost = cost
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        totalTokens = try c.decodeIfPresent(Int.self, forKey: .totalTokens) ?? 0
        inputTokens = try c.decodeIfPresent(Int.self, forKey: .inputTokens) ?? 0
        outputTokens = try c.decodeIfPresent(Int.self, forKey: .outputTokens) ?? 0
        thoughtTokens = try c.decodeIfPresent(Int.self, forKey: .thoughtTokens)
        cachedReadTokens = try c.decodeIfPresent(Int.self, forKey: .cachedReadTokens)
        cachedWriteTokens = try c.decodeIfPresent(Int.self, forKey: .cachedWriteTokens)
        // A zero is not a price (049 P2): see `Cost.init(wire:)`.
        cost = try c.decodeIfPresent(Cost.self, forKey: .cost).flatMap { $0.amount == 0 ? nil : $0 }
    }
}

public extension TurnUsage {
    /// Every usage report in these entries, added up: what one turn used, when a turn
    /// carries more than one (#465). Nil when there is none. A count only one report
    /// carries is kept rather than dropped, and costs in two currencies keep the first.
    static func total(of entries: [TranscriptEntry]) -> TurnUsage? {
        let reports = entries.compactMap { entry -> TurnUsage? in
            if case .usageRecorded(let usage) = entry.kind { return usage } else { return nil }
        }
        guard var total = reports.first else { return nil }
        func add(_ lhs: Int?, _ rhs: Int?) -> Int? {
            lhs == nil && rhs == nil ? nil : (lhs ?? 0) + (rhs ?? 0)
        }
        for usage in reports.dropFirst() {
            total.totalTokens += usage.totalTokens
            total.inputTokens += usage.inputTokens
            total.outputTokens += usage.outputTokens
            total.thoughtTokens = add(total.thoughtTokens, usage.thoughtTokens)
            total.cachedReadTokens = add(total.cachedReadTokens, usage.cachedReadTokens)
            total.cachedWriteTokens = add(total.cachedWriteTokens, usage.cachedWriteTokens)
            if let cost = usage.cost { total.cost = total.cost.map { $0.adding(cost) ?? $0 } ?? cost }
        }
        return total
    }
}

/// What a turn cost, in the runtime's own currency. Shown as sent: no conversion, no
/// estimate, and a total is kept per currency because adding two of them would be a
/// number nobody could check.
public struct Cost: Codable, Hashable, Sendable {
    public var amount: Decimal
    public var currency: String

    public init(amount: Decimal, currency: String) {
        self.amount = amount
        self.currency = currency
    }

    /// Nil for an amount of zero as well as for none. A runtime reports zero for a model it
    /// has no per-token price for — OpenCode's free Zen models, a subscription, a local
    /// model (049 research R2) — and no runtime bills a turn at exactly zero on purpose. So
    /// the meter says the cost is not measured rather than "$0", and no cost limit is ever
    /// taken to cover it (Alex, 2026-09-28: for every runtime).
    public init?(wire: JSONValue?) {
        guard let wire, let currency = wire["currency"]?.stringValue else { return nil }
        switch wire["amount"] {
        case .double(let value): self.amount = Decimal(value)
        case .int(let value): self.amount = Decimal(value)
        default: return nil
        }
        guard amount != 0 else { return nil }
        self.currency = currency
    }

    public func adding(_ other: Cost) -> Cost? {
        guard other.currency == currency else { return nil }
        return Cost(amount: amount + other.amount, currency: currency)
    }

    /// A running total written out for the eye: one number per currency, in currency
    /// order, joined rather than added. Nil when nothing has been spent, which is how
    /// the meter knows to show no cost rather than a zero.
    public static func total(of costToDate: [String: Decimal]) -> String? {
        guard !costToDate.isEmpty else { return nil }
        return costToDate
            .sorted { $0.key < $1.key }
            .map { $0.value.money(in: $0.key) }
            .joined(separator: " · ")
    }
}

public extension Decimal {
    /// A cost for the eye: whole units, to the nearest, in the currency's own sign —
    /// `$3`, not `$2.84`. Every figure of spending a person is shown goes through
    /// here, so the sidebar, the meter, the spending page and the phone agree on what
    /// a dollar looks like. Not for a limit: that is a number somebody typed, and it
    /// is shown as typed.
    func money(in currency: String) -> String {
        formatted(.currency(code: currency)
            .precision(.fractionLength(0))
            .rounded(rule: .toNearestOrAwayFromZero))
    }
}
