import Foundation

/// What the reader will allow to be spent.
///
/// Separate from `Usage.swift` deliberately. `Usage` is what a runtime reported —
/// a fact arriving from outside, which nobody chose. `CostLimits` is what a person
/// decided, and it is the only money in the app that is ever written by a hand.
///
/// Both limits are a `Cost` rather than a bare `Decimal`, because the currency is
/// part of the limit and not an assumption: spend in a currency the limit is not in
/// is counted and shown, and never compared. The app converts nothing and adds
/// nothing across currencies, here as everywhere else.
public struct CostLimits: Codable, Hashable, Sendable {
    /// The most any one agent may spend across its whole life.
    ///
    /// `nil` is no limit, and is the state before the reader has said anything, which
    /// is why the app behaves exactly as it did before this feature until they do.
    public var perAgent: Cost?

    /// The most everything may spend in one local day.
    ///
    /// `nil` is no limit, on the same terms as `perAgent`.
    public var daily: Cost?

    public init(perAgent: Cost? = nil, daily: Cost? = nil) {
        self.perAgent = perAgent
        self.daily = daily
    }

    /// Nothing is set, so nothing is gated and nothing is shown.
    public var isEmpty: Bool { perAgent == nil && daily == nil }

    /// What is left of `limit` after `spent`, in that one currency.
    ///
    /// Floored at zero: a limit that has been passed has no headroom, and a negative
    /// figure would read as an overdraft the app does not offer. `nil` when there is
    /// no limit in that currency, which is how a view knows to show nothing at all
    /// rather than an empty gauge.
    ///
    /// A limit of **zero is a real limit that is immediately reached**, and must never
    /// be collapsed into `nil`. `Optional` carries "unset" correctly; `amount == 0`
    /// meaning "off" would make the one limit that stops everything mean its opposite.
    public static func headroom(of limit: Cost?, against spent: [String: Decimal]) -> Decimal? {
        guard let limit else { return nil }
        let already = spent[limit.currency] ?? 0
        return max(0, limit.amount - already)
    }

    /// What is left of the per-agent limit in the currency it is set in.
    public func perAgentHeadroom(against spent: [String: Decimal]) -> Decimal? {
        Self.headroom(of: perAgent, against: spent)
    }

    /// What is left of the day's limit in the currency it is set in.
    public func dailyHeadroom(against spent: [String: Decimal]) -> Decimal? {
        Self.headroom(of: daily, against: spent)
    }

    /// Whether the day's limit has been reached by what has been spent today.
    ///
    /// *Reached*, not exceeded: the spec says an agent stops when its cost "reaches"
    /// the limit, and the day follows the same word. False when there is no daily
    /// limit, which is the state before the reader has said anything.
    public func isDayLimitReached(spentToday spent: [String: Decimal]) -> Bool {
        guard let daily else { return false }
        return (spent[daily.currency] ?? 0) >= daily.amount
    }
}
