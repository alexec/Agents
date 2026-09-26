import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// The sentences the Pool page, the notes and the phone share (052).
@Suite("What the pool says")
struct PoolWordsTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    @Test func eachStateReadsInWords() {
        var state = AllowanceState(credentialKey: "k", entryID: UUID(), since: now)
        #expect(PoolWords.state(state, now: now) == "Available")
        state.markOut(.allowanceSpent, until: now.addingTimeInterval(3600), payment: .allowance(label: nil), now: now, from: .typedFailure)
        #expect(PoolWords.state(state, now: now).hasPrefix("Out until "))
        state.markOut(.allowanceSpent, until: nil, payment: .allowance(label: nil), now: now, from: .words)
        #expect(PoolWords.state(state, now: now).contains("trying again after"))
        state.markOut(.creditUsedUp, until: nil, payment: .prepaid(amount: nil, expires: nil), now: now, from: .ledger)
        #expect(PoolWords.state(state, now: now) == "Credit used up")
        state.markOut(.creditExpired, until: nil, payment: .freeCredit(amount: nil, expires: now), now: now, from: .expiry)
        #expect(PoolWords.state(state, now: now) == "Free credit expired")
        state.markAvailable(now: now)
        _ = state.rateLimited(now: now, retryAt: now.addingTimeInterval(30), payment: .allowance(label: nil))
        #expect(PoolWords.state(state, now: now).hasPrefix("Rate limited · trying again at "))
    }

    @Test func eachPaymentHasItsCapsule() {
        #expect(PoolWords.payment(.allowance(label: "ChatGPT plan")) == "Allowance · ChatGPT plan")
        #expect(PoolWords.payment(.freeTier(reset: .gemini)) == "Free tier · resets daily")
        #expect(PoolWords.payment(.prepaid(amount: Cost(amount: 10, currency: "USD"), expires: nil),
                                  spent: .known(Cost(amount: Decimal(string: "3.2")!, currency: "USD")))
                .hasPrefix("Prepaid credit · ≈ "))
        #expect(PoolWords.payment(.freeCredit(amount: nil, expires: nil), spent: .unknown) == "Free credit · spending not known")
    }

    @Test func theNotesNameTheRuntime() {
        #expect(PoolWords.ranOut("claude", returnsAt: nil, now: now) == "Claude’s allowance ran out.")
        #expect(PoolWords.ranOut("codex", returnsAt: now.addingTimeInterval(60), now: now).hasPrefix("Codex’s allowance ran out, until "))
        #expect(PoolWords.creditGone("gemini") == "Gemini’s credit is used up.")
    }
}
