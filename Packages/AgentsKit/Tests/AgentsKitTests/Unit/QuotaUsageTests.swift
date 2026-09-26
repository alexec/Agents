import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// Gemini's turn usage (046, R7): no `usage` on the prompt's reply and no `usage_update`,
/// but `_meta.quota.token_count` on every ending. Tokens, never a cost it did not name.
@Suite("Gemini's turn usage")
struct QuotaUsageTests {
    /// The shape Gemini CLI 0.61.0 builds, read out of its ACP code on 2026-09-25.
    private let quota: JSONValue = [
        "token_count": ["input_tokens": 1200, "output_tokens": 340],
        "model_usage": [["model": "gemini-2.5-pro",
                         "token_count": ["input_tokens": 1200, "output_tokens": 340]]],
    ]

    @Test func tokensAreReadAndNoCostIsInvented() throws {
        let usage = try #require(ACPSession.quotaUsage(in: quota))
        #expect(usage.inputTokens == 1200)
        #expect(usage.outputTokens == 340)
        #expect(usage.totalTokens == 1540)
        #expect(usage.cost == nil)
    }

    /// A slash command Gemini answers itself reports zeros; that is nothing used, not a
    /// turn that cost nothing.
    @Test func aTurnThatUsedNothingSaysNothing() {
        let zero: JSONValue = ["token_count": ["input_tokens": 0, "output_tokens": 0], "model_usage": []]
        #expect(ACPSession.quotaUsage(in: zero) == nil)
    }

    @Test func anythingElseIsNoUsageRatherThanAFailure() {
        #expect(ACPSession.quotaUsage(in: nil) == nil)
        #expect(ACPSession.quotaUsage(in: ["token_count": "lots"]) == nil)
    }
}
