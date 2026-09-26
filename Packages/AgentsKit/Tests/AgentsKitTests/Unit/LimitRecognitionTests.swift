import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// One test per row of `contracts/acp-session-failure.md` (052). What is recognised
/// moves a chat; everything else never does.
@Suite("Recognising a spent allowance")
struct LimitRecognitionTests {
    private func typed(_ name: String) throws -> SessionFailure {
        try #require(SessionFailure.from(meta: SessionFailureDecodingTests.fixture(name)))
    }

    private var rejected: RateLimitInfo {
        RateLimitInfo(status: "rejected", resetsAt: Date(timeIntervalSince1970: 1_790_000_000))
    }

    // MARK: Layer 1, typed

    @Test func aQuotaIsSpentAndTakesThePlanWindowsReturn() throws {
        let recognition = LimitRecognition.classify(failure: try typed("quota-exhausted"), runtimeID: "claude",
                                                    rateLimit: rejected)
        #expect(recognition == .spent(resetsAt: Date(timeIntervalSince1970: 1_790_000_000)))
        #expect(recognition.moves)
    }

    @Test func aQuotaWithoutAWindowIsSpentWithNoTime() throws {
        #expect(LimitRecognition.classify(failure: try typed("quota-exhausted"), runtimeID: "codex") == .spent(resetsAt: nil))
    }

    @Test func aRateLimitIsRetriedNotMoved() throws {
        let recognition = LimitRecognition.classify(failure: try typed("rate-limited"), runtimeID: "claude")
        #expect(recognition == .rateLimited(retryAfter: nil))
        #expect(!recognition.moves)
    }

    @Test(arguments: ["budget-exhausted", "auth-required", "overloaded", "unknown-category"])
    func otherKindsAreSaidAndNeverMove(name: String) throws {
        let recognition = LimitRecognition.classify(failure: try typed(name), runtimeID: "claude")
        guard case .otherTyped = recognition else { Issue.record("\(name): \(recognition)"); return }
        #expect(!recognition.moves)
    }

    @Test func aWarningChangesNothing() throws {
        #expect(LimitRecognition.classify(failure: try typed("retry-warning"), runtimeID: "claude") == .none)
    }

    // MARK: Paid overage

    @Test func overageOnAPlanIsOut() throws {
        let info = try #require(RateLimitInfo.from(meta: SessionFailureDecodingTests.fixture("claude-rate-limit-overage")))
        let recognition = LimitRecognition.classify(runtimeID: "claude", rateLimit: info)
        #expect(recognition == .overage(resetsAt: Date(timeIntervalSince1970: 1_790_007_200)))
        #expect(recognition.moves)
    }

    @Test func overageOnPrepaidCreditIsWhatCreditIsFor() throws {
        let info = try #require(RateLimitInfo.from(meta: SessionFailureDecodingTests.fixture("claude-rate-limit-overage")))
        #expect(LimitRecognition.classify(runtimeID: "claude", rateLimit: info,
                                          payment: .prepaid(amount: nil, expires: nil)) == .none)
    }

    // MARK: Layer 2, words

    @Test(arguments: LimitRecognition.claudeUsageLimitPrefixes)
    func eachOfClaudesOwnPrefixesIsSpent(prefix: String) {
        #expect(LimitRecognition.classify(error: (-32603, "\(prefix) limit · resets 7pm"), runtimeID: "claude")
                == .spent(resetsAt: nil))
    }

    @Test func claudesWordsFromAnotherRuntimeAreJustWords() {
        #expect(LimitRecognition.classify(error: (-32603, "You've hit your stride"), runtimeID: "grok") == .none)
    }

    /// The rows of 046's `UsageLimitTests`, moved here and split in two.
    @Test func geminisSpentFreeTierIsSpent() {
        #expect(LimitRecognition.classify(error: (429, "You have exhausted your daily quota on this model."),
                                          runtimeID: "gemini") == .spent(resetsAt: nil))
    }

    @Test func geminisOtherLimitsAreRateLimits() {
        #expect(LimitRecognition.classify(error: (429, "Too many requests"), runtimeID: "gemini") == .rateLimited(retryAfter: nil))
        #expect(LimitRecognition.classify(error: (-32603, "RESOURCE_EXHAUSTED: rate limit exceeded"), runtimeID: "gemini")
                == .rateLimited(retryAfter: nil))
    }

    @Test(arguments: ["Error code: 429 - insufficient_quota", "Your credit balance is too low to access the API."])
    func aKeysCreditGoneIsSaid(message: String) {
        #expect(LimitRecognition.classify(error: (400, message), runtimeID: "codex") == .creditGone)
    }

    @Test func antigravitysExhaustedResourceIsRetriedFirst() {
        #expect(LimitRecognition.classify(runtimeError: "Resource has been exhausted (e.g. check quota).",
                                          runtimeID: "antigravity") == .rateLimited(retryAfter: nil))
        #expect(LimitRecognition.classify(runtimeError: "API key not valid. Please pass a valid API key.",
                                          runtimeID: "antigravity") == .none)
    }

    // MARK: Layer 3

    @Test func anythingElseIsNothing() {
        #expect(LimitRecognition.classify(error: (-32603, "Internal error"), runtimeID: "claude") == .none)
        #expect(LimitRecognition.classify(runtimeID: "claude") == .none)
    }
}
