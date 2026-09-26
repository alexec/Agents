import Foundation

/// A failure a runtime reported in a shape, rather than as a rejected prompt (052, R1).
///
/// Claude's and Codex's adapters both speak JetBrains' "AIR" session-failure extension,
/// and only to a client that says it does (see `ClientCapabilities.sessionFailures`).
/// Having said so, a turn the provider refused no longer comes back as an error: it
/// ends with `end_turn` and this under `_meta.jetbrains.air.sessionFailure`, on the
/// prompt's answer or on a `session_info_update`. Read as a plain `end_turn` it would
/// look finished, which is the one thing it must never do.
///
/// The adapters' own name for the kind is not on the wire. `category` and `actions`
/// together say it exactly — see `contracts/acp-session-failure.md` — and anything new
/// is kept as it was sent rather than guessed at.
public struct SessionFailure: Codable, Hashable, Sendable {
    /// The same id across revisions is the same failure, updated.
    public var id: String
    public var revision: Int
    /// `limit`, `access`, `service`, `connection`, `request`, `unknown` — or something a
    /// later adapter invents.
    public var category: String
    /// `error` or `warning`. A warning is a retry in progress and changes nothing.
    public var severity: String
    /// The sentence the runtime chose for the person. Shown as it is.
    public var title: String
    /// For whoever is debugging the runtime: logged, never shown.
    public var details: String?
    public var reason: String?
    /// `retry`, `login`, `new_session`, …
    public var actions: [String]

    public init(id: String, revision: Int = 1, category: String, severity: String = "error",
                title: String, details: String? = nil, reason: String? = nil, actions: [String] = []) {
        self.id = id
        self.revision = revision
        self.category = category
        self.severity = severity
        self.title = title
        self.details = details
        self.reason = reason
        self.actions = actions
    }

    /// Anything but a warning stops the turn. An unfamiliar severity is taken as the
    /// worse of the two: a turn wrongly left unfinished says so, one wrongly marked done
    /// hides a failure.
    public var isError: Bool { severity != "warning" }

    /// The failure in a `_meta`, if there is one. Nothing that cannot be read costs the
    /// turn: a shape we do not understand is no failure rather than a thrown error.
    public static func from(meta: JSONValue?) -> SessionFailure? {
        guard let failure = meta?["jetbrains"]?["air"]?["sessionFailure"],
              let id = failure["id"]?.stringValue,
              let category = failure["category"]?.stringValue,
              let title = failure["title"]?.stringValue else { return nil }
        return SessionFailure(
            id: id,
            revision: failure["revision"]?.intValue ?? 1,
            category: category,
            severity: failure["severity"]?.stringValue ?? "error",
            title: title,
            details: failure["details"]?.stringValue,
            reason: failure["reason"]?.stringValue,
            actions: failure["actions"]?.arrayValue?.compactMap(\.stringValue) ?? [])
    }

    /// The later of two reports of the same failure; a different failure replaces it.
    public func superseded(by other: SessionFailure) -> SessionFailure {
        guard other.id == id else { return other }
        return other.revision >= revision ? other : self
    }
}

/// What Claude says about its plan window on every `usage_update`, under
/// `_meta["_claude/rateLimit"]` (the SDK's `SDKRateLimitInfo`, 052 R2–R3).
///
/// The one place the app hears when an allowance comes back, and whether paid extra
/// usage has begun — both from the vendor, not guessed.
public struct RateLimitInfo: Codable, Hashable, Sendable {
    /// `allowed`, `allowed_warning` or `rejected`.
    public var status: String?
    public var resetsAt: Date?
    /// `five_hour`, `seven_day`, `seven_day_opus`, …
    public var rateLimitType: String?
    public var utilization: Double?
    public var overageStatus: String?
    public var overageResetsAt: Date?
    public var isUsingOverage: Bool?
    public var overageInUse: Bool?
    public var overageDisabledReason: String?

    public init(status: String? = nil, resetsAt: Date? = nil, rateLimitType: String? = nil,
                utilization: Double? = nil, overageStatus: String? = nil, overageResetsAt: Date? = nil,
                isUsingOverage: Bool? = nil, overageInUse: Bool? = nil, overageDisabledReason: String? = nil) {
        self.status = status
        self.resetsAt = resetsAt
        self.rateLimitType = rateLimitType
        self.utilization = utilization
        self.overageStatus = overageStatus
        self.overageResetsAt = overageResetsAt
        self.isUsingOverage = isUsingOverage
        self.overageInUse = overageInUse
        self.overageDisabledReason = overageDisabledReason
    }

    public static let metaKey = "_claude/rateLimit"

    public var isRejected: Bool { status == "rejected" }

    /// The account has started paying for use beyond its plan. The app never lets a
    /// chat carry on like that (FR-007, R3).
    public var isPayingOverage: Bool { isUsingOverage == true || overageInUse == true }

    public static func from(meta: JSONValue?) -> RateLimitInfo? {
        guard let info = meta?[metaKey], info.objectValue != nil else { return nil }
        return RateLimitInfo(
            status: info["status"]?.stringValue,
            resetsAt: seconds(info["resetsAt"]),
            rateLimitType: info["rateLimitType"]?.stringValue,
            utilization: number(info["utilization"]),
            overageStatus: info["overageStatus"]?.stringValue,
            overageResetsAt: seconds(info["overageResetsAt"]),
            isUsingOverage: info["isUsingOverage"]?.boolValue,
            overageInUse: info["overageInUse"]?.boolValue,
            overageDisabledReason: info["overageDisabledReason"]?.stringValue)
    }

    private static func number(_ value: JSONValue?) -> Double? {
        switch value {
        case .int(let v): Double(v)
        case .double(let v): v
        default: nil
        }
    }

    /// Unix seconds, as the SDK sends them.
    private static func seconds(_ value: JSONValue?) -> Date? {
        number(value).map { Date(timeIntervalSince1970: $0) }
    }
}
