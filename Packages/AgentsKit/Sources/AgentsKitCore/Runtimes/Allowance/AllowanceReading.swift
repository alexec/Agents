import Foundation

/// How much of a plan window a runtime says is used, for the Pool page to show.
///
/// Standard ACP has no way to ask this: `usage_update` is the session's context and
/// cost, not the account's allowance. Two runtimes say it in extensions of their own,
/// and each is read here. A reading is only ever shown. Whether a chat may run is
/// `AllowanceState.status`, which a stale percentage must never decide.
public struct AllowanceReading: Codable, Hashable, Sendable {
    /// The runtime's name for the window: Claude's `five_hour`, `seven_day`,
    /// `seven_day_opus`; Grok's `weekly`, `monthly`. Kept as sent.
    public var window: String?
    /// How much is used, from 0 to 1. Nil when the runtime said when it resets but not
    /// how much is gone, which Claude often does.
    public var used: Double?
    public var resetsAt: Date?
    /// The runtime refused for this window: none left, whatever `used` says.
    public var spent: Bool
    /// The runtime warned that it is nearly used up.
    public var nearlySpent: Bool
    /// When it was measured.
    public var at: Date

    public init(window: String? = nil, used: Double? = nil, resetsAt: Date? = nil,
                spent: Bool = false, nearlySpent: Bool = false, at: Date) {
        self.window = window
        self.used = used.map { min(max($0, 0), 1) }
        self.resetsAt = resetsAt
        self.spent = spent
        self.nearlySpent = nearlySpent
        self.at = at
    }

    /// What is left, from 0 to 1, where it is known.
    public var left: Double? {
        if spent { return 0 }
        return used.map { 1 - $0 }
    }

    /// A window that has since reset says nothing about the new one.
    public func isCurrent(now: Date) -> Bool {
        guard let resetsAt else { return true }
        return resetsAt > now
    }

    /// The same window, reset time and amount: a newer copy of this is not news.
    public func sameAs(_ other: AllowanceReading) -> Bool {
        window == other.window && used == other.used && resetsAt == other.resetsAt
            && spent == other.spent && nearlySpent == other.nearlySpent
    }

    // MARK: Claude

    /// Claude's plan window (`_meta["_claude/rateLimit"]` on `usage_update`). The SDK's
    /// `utilization` is a fraction; a number above one is taken as a percentage rather
    /// than shown as more than all of it. Nil when it names neither a window nor a time.
    public static func claude(_ info: RateLimitInfo, at: Date) -> AllowanceReading? {
        guard info.rateLimitType != nil || info.resetsAt != nil || info.utilization != nil else { return nil }
        let used = info.utilization.map { $0 > 1 ? $0 / 100 : $0 }
        return AllowanceReading(window: info.rateLimitType, used: used, resetsAt: info.resetsAt,
                                spent: info.isRejected, nearlySpent: info.status == "allowed_warning", at: at)
    }

    // MARK: Grok

    /// The answer to Grok's `_x.ai/billing`. `creditUsagePercent` and `currentPeriod`
    /// are its newer fields; `used` over `monthlyLimit` (cents) and `billingPeriodEnd`
    /// are the older ones it still sends, read only when the newer are missing.
    public static func grokBilling(_ result: JSONValue, at: Date) -> AllowanceReading? {
        guard let config = result["config"], config.objectValue != nil else { return nil }
        var used = number(config["creditUsagePercent"]).map { $0 / 100 }
        if used == nil, let limit = number(config["monthlyLimit"]?["val"]), limit > 0 {
            used = (number(config["used"]?["val"]) ?? 0) / limit
        }
        let period = config["currentPeriod"]
        let window: String? = switch period?["type"]?.stringValue {
        case "USAGE_PERIOD_TYPE_WEEKLY": "weekly"
        case "USAGE_PERIOD_TYPE_MONTHLY": "monthly"
        case nil: config["monthlyLimit"] != nil ? "monthly" : nil
        case let other?: other
        }
        let end = date(period?["end"]) ?? date(config["billingPeriodEnd"])
        guard used != nil || end != nil else { return nil }
        return AllowanceReading(window: window, used: used, resetsAt: end,
                                spent: (used ?? 0) >= 1, at: at)
    }

    private static func number(_ value: JSONValue?) -> Double? {
        switch value {
        case .int(let v): Double(v)
        case .double(let v): v
        default: nil
        }
    }

    /// RFC 3339, as Grok sends it: microseconds and a `+00:00` offset, which
    /// `ISO8601DateFormatter` will not read, so the fraction is dropped first.
    private static func date(_ value: JSONValue?) -> Date? {
        guard let text = value?.stringValue else { return nil }
        let whole = text.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        return ISO8601DateFormatter().date(from: whole)
    }
}
