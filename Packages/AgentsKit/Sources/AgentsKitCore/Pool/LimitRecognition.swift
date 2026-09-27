import Foundation

/// What a turn's ending says about the runtime's allowance (052, R1, R3).
public enum Recognition: Hashable, Sendable {
    /// The allowance is spent. `resetsAt` when the runtime said.
    case spent(resetsAt: Date?)
    /// A key's credit is gone (FR-001c).
    case creditGone
    /// Too many requests just now; try again (FR-006a). `retryAfter` when it said.
    case rateLimited(retryAfter: Date?)
    /// Paid extra usage has begun on a plan (FR-007).
    case overage(resetsAt: Date?)
    /// A typed failure of another kind: said, never switched on.
    case otherTyped(String)
    /// Nothing recognised. Never switched on (FR-006).
    case none

    /// Whether this moves a chat, given a pool to move to.
    public var moves: Bool {
        switch self {
        case .spent, .creditGone, .overage: true
        case .rateLimited, .otherTyped, .none: false
        }
    }
}

/// The whole rule for recognising a spent allowance, in three layers: the runtime's own
/// typed failure, then captured words, then nothing (052, R1). Every entry in the word
/// lists quotes something a runtime was seen to say.
public enum LimitRecognition {
    /// The Claude SDK's own prefixes for its usage-limit errors
    /// (`USAGE_LIMIT_ERROR_PREFIXES`, `@anthropic-ai/claude-agent-sdk` as vendored by
    /// `claude-agent-acp` 0.81.2). What a refused prompt's text starts with when the
    /// typed failure was not asked for.
    public static let claudeUsageLimitPrefixes = [
        "You've hit your", "You've reached your", "You're out of usage credits",
        "Your org is out of usage · add funds to continue", "Your org is out of usage · contact your admin",
        "Your seat type doesn't include usage credits", "Your seat type doesn't include usage",
        "Your usage allocation has been disabled by your admin", "Your group's usage limit is set to $0",
        "Fable 5 requires usage credits", "You're out of extra usage", "Your seat type doesn't include extra usage",
    ]

    /// Gemini's spent free tier (046, research R13).
    public static let geminiDailyQuota = "exhausted your daily quota"

    /// Copilot's monthly allowance refusal, captured on 2026-09-26.
    public static let copilotMonthlyQuota = "You have exceeded your monthly quota"

    /// Antigravity's spent-plan title and body, captured on 2026-09-27 from “hi Antigravity”:
    /// `Usage Limit Reached\n\nYou have reached your current quota for this period…`
    public static let antigravityUsageLimitTitle = "Usage Limit Reached"
    public static let antigravityUsageLimitBody = "You have reached your current quota"

    /// A key's credit gone: OpenAI's code and Anthropic's sentence.
    public static let creditGoneWords = ["insufficient_quota", "credit balance is too low"]

    /// Classify how a turn ended.
    ///
    /// - Parameters:
    ///   - failure: the typed failure on the turn, if any.
    ///   - error: a rejected prompt's code and message, if it was rejected.
    ///   - runtimeError: the sentence of a failure said in words (049), if any.
    ///   - rateLimit: the runtime's latest plan window, if it reports one.
    ///   - payment: how the entry the chat was on is paid for; overage only matters on
    ///     an allowance.
    public static func classify(failure: SessionFailure? = nil, error: (code: Int, message: String)? = nil,
                                runtimeError: String? = nil, runtimeID: String,
                                rateLimit: RateLimitInfo? = nil, payment: Payment = .allowance(label: nil)) -> Recognition {
        let resets = rateLimit?.isRejected == true ? rateLimit?.resetsAt : nil
        // Layer 1: the runtime's own classification.
        if let failure, failure.isError {
            guard failure.category == "limit" else { return .otherTyped(failure.title) }
            if failure.actions.isEmpty { return .spent(resetsAt: resets) }
            if failure.actions.contains("retry") { return .rateLimited(retryAfter: nil) }
            return .otherTyped(failure.title)
        }
        // Paid use has begun on a plan: out, whatever the turn itself did (R3).
        if case .allowance = payment, rateLimit?.isPayingOverage == true {
            return .overage(resetsAt: rateLimit?.overageResetsAt ?? rateLimit?.resetsAt)
        }
        // Layer 2: words that have been seen. Copilot and Antigravity can send a spent
        // refusal as a normal message ending in end_turn, or as a rejected prompt.
        if runtimeID == RuntimeCatalog.copilot.id,
           [error?.message, runtimeError].compactMap({ $0 }).contains(where: {
               $0.hasPrefix(copilotMonthlyQuota) || $0.hasPrefix("Error: " + copilotMonthlyQuota)
           }) {
            return .spent(resetsAt: resets)
        }
        if runtimeID == RuntimeCatalog.antigravity.id,
           [error?.message, runtimeError].compactMap({ $0 }).contains(where: isAntigravityUsageLimit) {
            return .spent(resetsAt: resets)
        }
        if let (code, message) = error {
            let lower = message.lowercased()
            if creditGoneWords.contains(where: { lower.contains($0) }) { return .creditGone }
            if runtimeID == RuntimeCatalog.claude.id,
               claudeUsageLimitPrefixes.contains(where: { message.hasPrefix($0) || message.contains(": \($0)") }) {
                return .spent(resetsAt: resets)
            }
            if lower.contains(geminiDailyQuota) { return .spent(resetsAt: nil) }
            if code == 429 || lower.contains("rate limit") || lower.contains("resource_exhausted") {
                return .rateLimited(retryAfter: nil)
            }
        }
        if let runtimeError {
            // Antigravity's 429 (049 tests): "Resource has been exhausted (e.g. check
            // quota)." Google uses the same words for a rate limit and a spent quota, so
            // it is retried, and only counts as spent when it keeps coming (R7).
            let lower = runtimeError.lowercased()
            if lower.contains("resource has been exhausted") || lower.contains("check quota") {
                return .rateLimited(retryAfter: nil)
            }
        }
        // Layer 3: nothing.
        return .none
    }

    /// Whether `text` is Antigravity's spent-plan message, with or without the title
    /// still on (turnError strips `Usage Limit Reached` when that is the matched prefix).
    public static func isAntigravityUsageLimit(_ text: String) -> Bool {
        let said = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return said.hasPrefix(antigravityUsageLimitTitle) || said.hasPrefix(antigravityUsageLimitBody)
    }
}
