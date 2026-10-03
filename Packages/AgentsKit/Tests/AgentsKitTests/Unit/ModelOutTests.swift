import Foundation
import Testing
@testable import AgentsKitCore

/// A model out, and a runtime answering again, in the allowance state (#140).
@Suite("A model out of the pool")
struct ModelOutTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private func state() -> AllowanceState {
        AllowanceState(credentialKey: "opencode:sign-in", entryID: UUID(), since: now)
    }

    @Test func aProviderFailureIsToldApartByItsWords() {
        #expect(ProviderFailure.recognises(JSONRPCError(code: -32603, message: "Upstream request failed: Endpoint is unavailable")))
        #expect(ProviderFailure.recognises(JSONRPCError(code: -32603, message: "Internal error",
                                                        data: ["message": "Error from provider: 503"])))
        #expect(!ProviderFailure.recognises(JSONRPCError(code: -32603, message: "Internal error")))
        // Another code is never a provider's failure, whatever it says.
        #expect(!ProviderFailure.recognises(JSONRPCError(code: -32000, message: "Upstream request failed")))
        #expect(ProviderFailure.recognises(words: "Upstream request failed: Endpoint is unavailable"))
    }

    @Test func aModelIsMarkedOnceAndLapsesAfterFourHours() {
        var state = state()
        let first = state.markModelFailed("free", name: "Free", now: now)
        let again = state.markModelFailed("free", name: "Free", now: now.addingTimeInterval(60))
        #expect(first)
        #expect(!again)
        #expect(!state.isOut)
        #expect(state.isUsable(now: now))
        #expect(PoolWords.stateWithModels(state, now: now).hasPrefix("Available · Model Free out since "))

        let later = now.addingTimeInterval(AllowanceState.retryWithoutATime)
        #expect(state.modelsOut(now: later).isEmpty)
        let settled = state.settle(now: later)
        #expect(settled)
        #expect(state.modelsOut == nil)
        #expect(PoolWords.stateWithModels(state, now: later) == "Available")
    }

    @Test func answeringBringsBackAFailedRuntimeButNotASpentOne() {
        var failed = state()
        failed.markFailed(now: now)
        let back = failed.answering(now: now)
        #expect(back)
        #expect(failed.status == .available)

        var spent = state()
        spent.markOut(.allowanceSpent, until: nil, payment: .allowance(label: nil), now: now, from: .words)
        let spentBack = spent.answering(now: now)
        #expect(!spentBack)
        #expect(spent.isOut)
    }

    @Test func aStateWrittenBeforeModelsOutStillReads() throws {
        let older = #"{"credentialKey":"opencode:sign-in","entryID":"\#(UUID().uuidString)","status":{"available":{}},"since":0,"learnedFrom":"person","spent":{"known":{}},"rateLimitStreak":[]}"#
        let state = try JSONDecoder().decode(AllowanceState.self, from: Data(older.utf8))
        #expect(state.modelsOut == nil)
    }
}
