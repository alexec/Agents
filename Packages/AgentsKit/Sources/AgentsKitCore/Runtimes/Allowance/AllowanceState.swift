import Foundation

/// Whether one credential can be used now, and if not, until when (052).
///
/// Kept per credential, not per entry or per host: a server's Codex relaying the Mac's
/// ChatGPT plan is the same plan, so when it is spent on one it is spent on both (R6).
public struct AllowanceState: Codable, Hashable, Sendable {
    public var credentialKey: String
    /// The first entry with this credential. Others with the same key share this state.
    public var entryID: UUID
    public var status: Status
    /// When `status` last changed.
    public var since: Date
    public var learnedFrom: Source
    /// The latest plan window the runtime reported, for the return time (R2).
    public var lastRateLimit: RateLimitInfo?
    /// A measured plan window. This is display data, never evidence that a turn can run.
    public var reading: AllowanceReading?
    /// What the app has recorded spending on this credential, for credit entries.
    public var spent: Spent
    /// Rate limits in a row, trimmed to the policy's window (R7).
    public var rateLimitStreak: [Date]

    public init(credentialKey: String, entryID: UUID, status: Status = .available, since: Date,
                learnedFrom: Source = .person, lastRateLimit: RateLimitInfo? = nil,
                reading: AllowanceReading? = nil,
                spent: Spent = .known(nil), rateLimitStreak: [Date] = []) {
        self.credentialKey = credentialKey
        self.entryID = entryID
        self.status = status
        self.since = since
        self.learnedFrom = learnedFrom
        self.lastRateLimit = lastRateLimit
        self.reading = reading
        self.spent = spent
        self.rateLimitStreak = rateLimitStreak
    }

    public enum Status: Codable, Hashable, Sendable {
        case available
        /// Too many requests just now. Not out: nothing moves (FR-006a).
        case rateLimited(until: Date)
        /// `until` when the runtime said; `retryAfter` is the next four-hour check.
        /// Credit has neither and never comes back by itself (FR-001c).
        case out(until: Date?, retryAfter: Date?, why: OutReason)
    }

    public enum OutReason: String, Codable, Hashable, Sendable {
        case allowanceSpent, overage, creditUsedUp, creditExpired, rateLimitPersisted, runtimeFailed
    }

    public enum Source: String, Codable, Hashable, Sendable {
        case typedFailure, words, overageReport, ledger, expiry, person, runtimeFailure
    }

    /// `known(nil)` is nothing recorded yet; `unknown` is a runtime that never says what
    /// it cost, which the page says rather than showing zero (FR-001b).
    public enum Spent: Codable, Hashable, Sendable {
        case known(Cost?)
        case unknown
    }

    /// How often to check an allowance that gave no return time.
    public static let retryWithoutATime: TimeInterval = 4 * 3600

    // MARK: Reading

    /// The status as of `now`, with short rate limits that have run out applied. A reading,
    /// not a change: the stored state moves when `settle(now:)` is called.
    public func current(now: Date) -> Status {
        switch status {
        case .rateLimited(let until) where until <= now: return .available
        default: return status
        }
    }

    /// Whether a chat may be sent here now. An entry without a stated return stays out
    /// until the scheduled read-only check succeeds.
    public func isUsable(now: Date) -> Bool {
        switch current(now: now) {
        case .available, .rateLimited: return true
        case .out: return false
        }
    }

    public var isOut: Bool { if case .out = status { return true } else { return false } }

    /// When it is expected back, for "resumes at" and the earliest return (FR-016).
    /// When the provider said it comes back: never the app's own retry time, which is a
    /// guess to try again, not a return (US4 waits only on this).
    public var knownReturn: Date? {
        switch status {
        case .available: nil
        case .rateLimited(let until): until
        case .out(let until, _, _): until
        }
    }

    /// A plan's sign-in, the same on the Mac and on every server that relays it (047,
    /// 056): what one learns about it, the other needs to know. A key keeps its own.
    public var isShared: Bool { credentialKey.hasSuffix(":sign-in") }

    public var returnsAt: Date? {
        switch status {
        case .available: return nil
        case .rateLimited(let until): return until
        case .out(let until, let retryAfter, _): return until ?? retryAfter
        }
    }

    // MARK: Changing

    /// Apply the short rate-limit clock. A spent allowance needs a successful check.
    @discardableResult
    public mutating func settle(now: Date) -> Bool {
        let settled = current(now: now)
        guard settled != status else { return false }
        status = settled
        since = now
        rateLimitStreak = []
        return true
    }

    /// A check failed or could not run. Keep the credential out and try again later.
    public mutating func deferCheck(now: Date) {
        guard case .out(let until, _, let why) = status else { return }
        status = .out(until: until, retryAfter: now.addingTimeInterval(Self.retryWithoutATime), why: why)
    }

    /// Spent. `until` is the runtime's own return time. Every credential gets a check
    /// every four hours, whether the runtime gave a time or not: a key's credit too, now
    /// the app keeps no ledger of it (065) and the provider is what says it is used up.
    public mutating func markOut(_ why: OutReason, until: Date?, payment: Payment, now: Date, from source: Source) {
        let back: Date?
        let retry: Date?
        switch payment {
        case .freeCredit, .prepaid:
            back = until
            retry = now.addingTimeInterval(Self.retryWithoutATime)
        case .freeTier(let reset):
            back = until ?? reset.next(after: now)
            retry = now.addingTimeInterval(Self.retryWithoutATime)
        case .allowance:
            back = until
            retry = now.addingTimeInterval(Self.retryWithoutATime)
        }
        status = .out(until: back, retryAfter: retry, why: why)
        since = now
        learnedFrom = source
        rateLimitStreak = []
    }

    /// A runtime failed without a recognised allowance refusal. It stays out
    /// until it passes a check or finishes a later turn, even when it uses credit.
    @discardableResult
    public mutating func markFailed(now: Date) -> Bool {
        guard !isOut else { return false }
        status = .out(until: nil, retryAfter: now.addingTimeInterval(Self.retryWithoutATime), why: .runtimeFailed)
        since = now
        learnedFrom = .runtimeFailure
        rateLimitStreak = []
        return true
    }

    /// A chat on it was rate limited and will try again at `retryAt`. Shown, and over
    /// by itself at that time. Whether the limit has persisted is the chat's streak,
    /// not this (065, `RateLimitPolicy.streak`).
    public mutating func rateLimited(now: Date, retryAt: Date) {
        status = .rateLimited(until: retryAt)
        since = now
    }

    /// A turn worked here: whatever was holding it is over.
    public mutating func worked(now: Date) {
        guard status != .available || !rateLimitStreak.isEmpty else { return }
        status = .available
        since = now
        rateLimitStreak = []
    }

    /// The person says it is back: bought more credit, a new month began (FR-023). What
    /// was spent is counted from nothing again, since what it was spent from is gone:
    /// otherwise the ledger would call new credit used up at once.
    public mutating func markAvailable(now: Date) {
        status = .available
        spent = .known(nil)
        since = now
        learnedFrom = .person
        rateLimitStreak = []
    }

    /// What makes two entries one allowance: the runtime and the credential it runs on.
    /// A plan is the runtime's own sign-in, the same on the Mac and on every server that
    /// relays it (047); a key is the lent credential.
    public static func credentialKey(for entry: PoolEntry) -> String {
        "\(entry.runtimeID):\(entry.credentialRef ?? "sign-in")"
    }
}

/// How rate limits are retried before they count as spent (052, R7). Defaults, not
/// settings, in this version.
public struct RateLimitPolicy: Hashable, Sendable {
    /// Waits before the first and second retries when the runtime gave no time.
    public var delays: [TimeInterval]
    /// How far back a streak counts.
    public var window: TimeInterval
    /// How many in the window make it out.
    public var persistsAfter: Int

    public static let standard = RateLimitPolicy(delays: [30, 120], window: 600, persistsAfter: 3)

    public func delay(forAttempt attempt: Int) -> TimeInterval {
        delays.isEmpty ? 30 : delays[min(attempt, delays.count - 1)]
    }

    /// One chat's refusals within the window, with this one added, and whether that
    /// many means the limit has persisted (three within ten minutes, R7). The streak is
    /// the chat's own: another chat's refusals on the same runtime do not count (065).
    public func streak(_ earlier: [Date], adding now: Date) -> (streak: [Date], persists: Bool) {
        let streak = earlier.filter { now.timeIntervalSince($0) < window } + [now]
        return (streak, streak.count >= persistsAfter)
    }
}
