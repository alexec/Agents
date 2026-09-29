import Foundation

/// When a free tier's quota comes back (052). Gemini's daily quota resets at midnight
/// Pacific; a free tier we know nothing about falls back to trying again in an hour.
public enum ResetRule: Codable, Hashable, Sendable {
    case dailyAt(hour: Int, timeZone: String)
    case unknown

    public static let gemini = ResetRule.dailyAt(hour: 0, timeZone: "America/Los_Angeles")

    /// The first reset strictly after `date`. Worked in the rule's own time zone, so a
    /// daylight-saving change moves it with the clock rather than by an hour.
    public func next(after date: Date) -> Date? {
        guard case .dailyAt(let hour, let zoneID) = self, let zone = TimeZone(identifier: zoneID) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.nextDate(after: date, matching: DateComponents(hour: hour, minute: 0, second: 0),
                                 matchingPolicy: .nextTime)
    }
}

/// How one pool entry is paid for (052, FR-001a).
///
/// There is deliberately no case for open-ended billing. A key whose spending has no
/// hard stop cannot be written down here, so it cannot be stored, so it can never be
/// carried onto (SC-002).
public enum Payment: Codable, Hashable, Sendable {
    /// A plan or account sign-in: a Claude subscription, a ChatGPT plan, Copilot, a
    /// Google account. The label is what the runtime says the plan is, where it says.
    case allowance(label: String?)
    /// A key with no billing account behind it: the provider refuses rather than
    /// charges, and the quota comes back on its own schedule.
    case freeTier(reset: ResetRule)
    /// A trial or promotional grant on a key.
    case freeCredit(amount: Cost?, expires: Date?)
    /// A balance topped up once, with auto-recharge off, as the person says.
    case prepaid(amount: Cost?, expires: Date?)

    /// Credit that, once used, does not come back by itself (FR-001c).
    public var isCredit: Bool {
        switch self {
        case .freeCredit, .prepaid: true
        case .allowance, .freeTier: false
        }
    }

    public var amount: Cost? {
        switch self {
        case .freeCredit(let amount, _), .prepaid(let amount, _): amount
        case .allowance, .freeTier: nil
        }
    }

    public var expires: Date? {
        switch self {
        case .freeCredit(_, let expires), .prepaid(_, let expires): expires
        case .allowance, .freeTier: nil
        }
    }
}

/// One runtime with one way of paying for it (052, FR-001).
public struct PoolEntry: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var runtimeID: String
    public var payment: Payment
    /// Which lent credential it runs on: a `CredentialKind` raw value. `nil` is the
    /// runtime's own sign-in.
    public var credentialRef: String?

    public init(id: UUID = UUID(), runtimeID: String, payment: Payment,
                credentialRef: String? = nil) {
        self.id = id
        self.runtimeID = runtimeID
        self.payment = payment
        self.credentialRef = credentialRef
    }

    public var credentialKind: CredentialKind? { credentialRef.flatMap(CredentialKind.init(rawValue:)) }

    /// Its key is one this Mac lends to its runtime (046). None else can run a pool entry:
    /// Codex's OpenAI key is gone (047), and so are Claude's tokens (056).
    public var hasAKeyToLend: Bool {
        guard let kind = credentialKind else { return false }
        return kind.isLentOnTheMac && kind.runtimeID == runtimeID
    }

    /// Runs on a key rather than a sign-in. Every kind Settings still takes is a key (056).
    public var isKeyed: Bool { credentialKind != nil }
}
