import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// A provider's quota or rate limit is said in its own words, not as a runtime that fell
/// over (046, FR-018).
@Suite("A provider's limit")
struct UsageLimitTests {
    @Test func geminisSpentFreeTierIsALimit() {
        let error = JSONRPCError(code: 429, message: "You have exhausted your daily quota on this model.")
        #expect(DaemonCore.usageLimit(error) == "You have exhausted your daily quota on this model.")
    }

    @Test func soIsOneThatSaysSoWithAnotherCode() {
        #expect(DaemonCore.usageLimit(JSONRPCError(code: -32603, message: "RESOURCE_EXHAUSTED: rate limit exceeded")) != nil)
    }

    @Test func anythingElseIsNot() {
        #expect(DaemonCore.usageLimit(JSONRPCError(code: -32603, message: "Internal error")) == nil)
        #expect(DaemonCore.usageLimit(CancellationError()) == nil)
    }
}
