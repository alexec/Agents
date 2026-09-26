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
    /// The model to use when the chat's model is in no level; `nil` is "as the chat had".
    public var fallbackModel: JSONValue?

    public init(id: UUID = UUID(), runtimeID: String, payment: Payment,
                credentialRef: String? = nil, fallbackModel: JSONValue? = nil) {
        self.id = id
        self.runtimeID = runtimeID
        self.payment = payment
        self.credentialRef = credentialRef
        self.fallbackModel = fallbackModel
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

/// One model, and an effort where the runtime has one, in a level's column.
public struct Cell: Codable, Hashable, Sendable {
    public var model: JSONValue
    public var effort: JSONValue?
    public var effortOptionID: String?

    public init(model: JSONValue, effort: JSONValue? = nil, effortOptionID: String? = nil) {
        self.model = model
        self.effort = effort
        self.effortOptionID = effortOptionID
    }
}

/// A row of Matching models: a level the person names, with a model per runtime (052).
public struct Level: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    /// Keyed by runtime id, not entry: two entries for one runtime share its column.
    public var cells: [String: Cell]

    public init(id: UUID = UUID(), name: String, cells: [String: Cell] = [:]) {
        self.id = id
        self.name = name
        self.cells = cells
    }
}

/// The person's pool (`pool.json`, 052).
public struct PoolSettings: Codable, Hashable, Sendable {
    public var isOn: Bool
    /// In the order to try.
    public var entries: [PoolEntry]
    public var levels: [Level]

    public init(isOn: Bool = false, entries: [PoolEntry] = [], levels: [Level] = []) {
        self.isOn = isOn
        self.entries = entries
        self.levels = levels
    }

    /// Nothing moves with fewer than two entries (FR-003).
    public var isEffective: Bool { isOn && entries.count >= 2 }

    public func entry(_ id: UUID?) -> PoolEntry? { entries.first { $0.id == id } }

    /// Why a pool cannot be kept, in a sentence the Settings page can show.
    public enum Invalid: Error, Hashable, Sendable {
        case unknownRuntime(String)
        case keyWithoutAHardStop(runtimeID: String)
        case keyAsAnAllowance(runtimeID: String)
        case amountNotPositive(runtimeID: String)
        case modelInTwoLevels(runtimeID: String, first: String, second: String)
        case emptyLevelName
        /// A key this Mac does not lend to that runtime: only Gemini's is, now that Codex
        /// and Claude on servers go through the Mac's own sign-in, relayed (047, 056).
        case noKeyToLend(runtimeID: String)
        /// Credit, free or prepaid, is only ever on a key.
        case creditWithoutAKey(runtimeID: String)

        public var sentence: String {
            switch self {
            case .unknownRuntime(let id):
                "There is no runtime called \(id)."
            case .keyWithoutAHardStop(let id):
                "A key for \(Self.name(id)) can only join the pool on a free tier, free credit, or prepaid credit with auto-recharge off."
            case .keyAsAnAllowance(let id):
                "\(Self.name(id)) on an API key is paid by use, so it cannot be an allowance."
            case .amountNotPositive(let id):
                "The credit for \(Self.name(id)) has to be more than nothing."
            case .modelInTwoLevels(let id, let first, let second):
                "A model can be in only one level for \(Self.name(id)); it is in both \(first) and \(second)."
            case .emptyLevelName:
                "A level needs a name."
            case .noKeyToLend(let id):
                "\(Self.name(id)) has no key this Mac lends, so it joins the pool on its own sign-in."
            case .creditWithoutAKey(let id):
                "Credit for \(Self.name(id)) needs a key; on its sign-in it is an allowance."
            }
        }

        private static func name(_ id: String) -> String { RuntimeCatalog.runtime(id: id)?.name ?? id }
    }

    /// The pool without entries on a key this Mac no longer lends: kept from before Codex's
    /// OpenAI key went (047). Dropped rather than refusing the whole file, so the rest of
    /// the pool still works; the names of what went are returned to be said.
    public func droppingKeysNotLent() -> (pool: PoolSettings, dropped: [String]) {
        var kept = self
        kept.entries = entries.filter { $0.credentialRef == nil || $0.hasAKeyToLend }
        let dropped = entries.filter { $0.credentialRef != nil && !$0.hasAKeyToLend }.map(\.runtimeID)
        return (kept, dropped)
    }

    /// Everything that must hold before the pool is kept (FR-001a, FR-032).
    public func validate() throws(Invalid) {
        for entry in entries {
            guard RuntimeCatalog.runtime(id: entry.runtimeID) != nil else { throw .unknownRuntime(entry.runtimeID) }
            // Gemini has no sign-in an individual can use but a key (046), so it is
            // never an allowance, whatever the entry says it runs on.
            if entry.credentialRef != nil, !entry.hasAKeyToLend { throw .noKeyToLend(runtimeID: entry.runtimeID) }
            let keyed = entry.isKeyed || entry.runtimeID == RuntimeCatalog.gemini.id
            if !keyed, entry.payment.isCredit { throw .creditWithoutAKey(runtimeID: entry.runtimeID) }
            if keyed, case .allowance = entry.payment { throw .keyAsAnAllowance(runtimeID: entry.runtimeID) }
            if let amount = entry.payment.amount, amount.amount <= 0 { throw .amountNotPositive(runtimeID: entry.runtimeID) }
        }
        var seen: [String: [JSONValue: String]] = [:]
        for level in levels {
            guard !level.name.trimmingCharacters(in: .whitespaces).isEmpty else { throw .emptyLevelName }
            for (runtimeID, cell) in level.cells {
                if let other = seen[runtimeID]?[cell.model] {
                    throw .modelInTwoLevels(runtimeID: runtimeID, first: other, second: level.name)
                }
                seen[runtimeID, default: [:]][cell.model] = level.name
            }
        }
    }
}
