import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// Every transition in `data-model.md` § AllowanceState (052).
@Suite("An allowance's state")
struct AllowanceStateTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private func state() -> AllowanceState {
        AllowanceState(credentialKey: "claude:sign-in", entryID: UUID(), since: now)
    }

    @Test func spentWithATimeComesBackAtThatTime() {
        var state = state()
        let back = now.addingTimeInterval(5 * 3600)
        state.markOut(.allowanceSpent, until: back, payment: .allowance(label: nil), now: now, from: .typedFailure)
        #expect(!state.isUsable(now: now))
        #expect(state.returnsAt == back)
        #expect(state.current(now: back) == .available)
        let changed = state.settle(now: back)
        #expect(changed)
        #expect(state.status == .available)
    }

    @Test func spentWithoutATimeIsTriedAgainAfterAnHour() {
        var state = state()
        state.markOut(.allowanceSpent, until: nil, payment: .allowance(label: nil), now: now, from: .words)
        #expect(!state.isUsable(now: now.addingTimeInterval(3599)))
        #expect(state.isUsable(now: now.addingTimeInterval(3600)))
        // Tried again, not declared back: that is a turn working.
        #expect(state.isOut)
        state.worked(now: now.addingTimeInterval(3700))
        #expect(state.status == .available)
    }

    @Test func aRateLimitIsNotOut() {
        var state = state()
        let persisted = state.rateLimited(now: now, retryAt: now.addingTimeInterval(30), payment: .allowance(label: nil))
        #expect(!persisted)
        #expect(!state.isOut)
        #expect(state.isUsable(now: now))
    }

    @Test func threeRateLimitsInTenMinutesAreOut() {
        var state = state()
        let payment = Payment.allowance(label: nil)
        let r1 = state.rateLimited(now: now, retryAt: now.addingTimeInterval(30), payment: payment)
        #expect(!r1)
        let r2 = state.rateLimited(now: now.addingTimeInterval(30), retryAt: now.addingTimeInterval(150), payment: payment)
        #expect(!r2)
        let r3 = state.rateLimited(now: now.addingTimeInterval(150), retryAt: now.addingTimeInterval(180), payment: payment)
        #expect(r3)
        guard case .out(nil, let retry?, .rateLimitPersisted) = state.status else { Issue.record("\(state.status)"); return }
        #expect(retry == now.addingTimeInterval(150 + 3600))
    }

    @Test func rateLimitsFarApartDoNotAddUp() {
        var state = state()
        let payment = Payment.allowance(label: nil)
        _ = state.rateLimited(now: now, retryAt: now, payment: payment)
        _ = state.rateLimited(now: now.addingTimeInterval(700), retryAt: now, payment: payment)
        let r4 = state.rateLimited(now: now.addingTimeInterval(1400), retryAt: now, payment: payment)
        #expect(!r4)
    }

    @Test func usedUpCreditNeverComesBackOnATimer() {
        var state = state()
        let payment = Payment.prepaid(amount: Cost(amount: 10, currency: "USD"), expires: nil)
        state.markOut(.creditUsedUp, until: nil, payment: payment, now: now, from: .words)
        #expect(state.returnsAt == nil)
        #expect(!state.isUsable(now: now.addingTimeInterval(365 * 86400)))
        let changed = state.settle(now: now.addingTimeInterval(365 * 86400))
        #expect(!changed)
    }

    @Test func aFreeTierIsBackAtTheNextMidnightPacific() throws {
        var state = state()
        let payment = Payment.freeTier(reset: .gemini)
        state.markOut(.allowanceSpent, until: nil, payment: payment, now: now, from: .words)
        let back = try #require(state.returnsAt)
        var pacific = Calendar(identifier: .gregorian)
        pacific.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        #expect(pacific.component(.hour, from: back) == 0)
        #expect(back > now && back.timeIntervalSince(now) <= 86400)
        #expect(state.current(now: back) == .available)
    }

    @Test func theResetFollowsTheClockAcrossDaylightSaving() throws {
        // 2 November 2026, the day US clocks go back: midnight still.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let evening = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 22)))
        let next = try #require(ResetRule.gemini.next(after: evening))
        #expect(calendar.dateComponents([.day, .hour], from: next) == DateComponents(day: 2, hour: 0))
    }

    @Test func markingAvailableIsThePersonsWord() {
        var state = state()
        state.markOut(.creditUsedUp, until: nil, payment: .freeCredit(amount: nil, expires: nil), now: now, from: .ledger)
        state.markAvailable(now: now)
        #expect(state.status == .available)
        #expect(state.learnedFrom == .person)
    }

    @Test func creditIsUsedUpByTheLedgerBeforeTheProviderSaysSo() {
        var state = state()
        let payment = Payment.prepaid(amount: Cost(amount: Decimal(string: "0.05")!, currency: "USD"), expires: nil)
        let turn = Cost(amount: Decimal(string: "0.03")!, currency: "USD")
        let r5 = state.add(cost: turn, payment: payment, now: now)
        #expect(!r5)
        let r6 = state.add(cost: turn, payment: payment, now: now)
        #expect(r6)
        guard case .out(nil, nil, .creditUsedUp) = state.status else { Issue.record("\(state.status)"); return }
    }

    @Test func aRuntimeThatNeverSaysWhatItCostIsUnknownNotZero() {
        var state = state()
        let payment = Payment.freeCredit(amount: Cost(amount: 1, currency: "USD"), expires: nil)
        let r7 = state.add(cost: nil, payment: payment, now: now)
        #expect(!r7)
        #expect(state.spent == .unknown)
        let r8 = state.add(cost: Cost(amount: 5, currency: "USD"), payment: payment, now: now)
        #expect(!r8)
    }

    @Test func anExpiredGrantIsOut() {
        var state = state()
        let payment = Payment.freeCredit(amount: nil, expires: now.addingTimeInterval(-60))
        let r9 = state.checkExpiry(payment: payment, now: now)
        #expect(r9)
        guard case .out(nil, nil, .creditExpired) = state.status else { Issue.record("\(state.status)"); return }
    }

    @Test func aRelayedPlanIsTheSamePlan() {
        let mac = PoolEntry(runtimeID: "codex", payment: .allowance(label: "ChatGPT plan"))
        let server = PoolEntry(runtimeID: "codex", payment: .allowance(label: "ChatGPT plan"))
        let keyed = PoolEntry(runtimeID: "codex", payment: .prepaid(amount: nil, expires: nil),
                              credentialRef: CredentialKind.openAIAPIKey.rawValue)
        #expect(AllowanceState.credentialKey(for: mac) == AllowanceState.credentialKey(for: server))
        #expect(AllowanceState.credentialKey(for: mac) != AllowanceState.credentialKey(for: keyed))
    }
}
