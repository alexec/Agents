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

    @Test func aStatedResetIsShownButDoesNotBringItBack() {
        var state = state()
        let back = now.addingTimeInterval(5 * 3600)
        state.markOut(.allowanceSpent, until: back, payment: .allowance(label: nil), now: now, from: .typedFailure)
        #expect(!state.isUsable(now: now))
        #expect(state.returnsAt == back)
        guard case .out(back, let retry?, .allowanceSpent) = state.status else { Issue.record("\(state.status)"); return }
        #expect(retry == now.addingTimeInterval(4 * 3600))
        // Past the provider's time: still out, until a check or a turn works.
        let later = back.addingTimeInterval(60)
        #expect(!state.isUsable(now: later))
        let changed = state.settle(now: later)
        #expect(!changed)
        #expect(state.isOut)
    }

    @Test func spentWithoutATimeIsCheckedEveryFourHours() {
        var state = state()
        state.markOut(.allowanceSpent, until: nil, payment: .allowance(label: nil), now: now, from: .words)
        guard case .out(nil, let retry?, _) = state.status else { Issue.record("\(state.status)"); return }
        #expect(retry == now.addingTimeInterval(4 * 3600))
        // The check time is permission to ask, never usable by itself.
        #expect(!state.isUsable(now: retry))
        let failedAt = retry.addingTimeInterval(30)
        state.deferCheck(now: failedAt)
        guard case .out(nil, let next?, .allowanceSpent) = state.status else { Issue.record("\(state.status)"); return }
        #expect(next == failedAt.addingTimeInterval(4 * 3600))
        state.worked(now: next)
        #expect(state.status == .available)
    }

    @Test func aFailedRuntimeIsOutUntilItWorks() {
        var state = state()
        let marked = state.markFailed(now: now)
        #expect(marked)
        guard case .out(nil, let retry?, .runtimeFailed) = state.status else { Issue.record("\(state.status)"); return }
        #expect(retry == now.addingTimeInterval(4 * 3600))
        #expect(state.learnedFrom == .runtimeFailure)
        #expect(!state.isUsable(now: retry))
        // Already out for a more specific reason: that reason stays.
        var spent = self.state()
        spent.markOut(.allowanceSpent, until: nil, payment: .allowance(label: nil), now: now, from: .words)
        let markedAgain = spent.markFailed(now: now)
        #expect(!markedAgain)
        guard case .out(_, _, .allowanceSpent) = spent.status else { Issue.record("\(spent.status)"); return }
        state.worked(now: retry)
        #expect(state.status == .available)
    }

    @Test func aRateLimitIsNotOut() {
        var state = state()
        state.rateLimited(now: now, retryAt: now.addingTimeInterval(30))
        #expect(!state.isOut)
        #expect(state.isUsable(now: now))
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
        #expect(!state.isUsable(now: back))
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
        // Any credential but the sign-in is another allowance; the pool no longer takes a
        // Codex key (047), but the rule is the credential's, not the runtime's.
        let keyed = PoolEntry(runtimeID: "codex", payment: .prepaid(amount: nil, expires: nil),
                              credentialRef: "another-credential")
        #expect(AllowanceState.credentialKey(for: mac) == AllowanceState.credentialKey(for: server))
        #expect(AllowanceState.credentialKey(for: mac) != AllowanceState.credentialKey(for: keyed))
    }

    @Test func theCheckRunsOnASmallModelOrTheDefault() {
        func choice(_ value: String, _ name: String, _ description: String? = nil) -> ConfigChoice {
            ConfigChoice(value: .string(value), name: name, description: description)
        }
        let claude = [choice("default", "Default (recommended)"), choice("opus", "Opus"), choice("haiku", "Haiku")]
        #expect(DaemonCore.probeModel(in: claude)?.name == "Haiku")
        // Codex names none small; its descriptions do. Never its first, frontier model.
        let codex = [choice("gpt-6-astra", "6 Astra", "Frontier intelligence for the most demanding work."),
                     choice("gpt-6-sol", "6 Sol", "Workhorse model for coding and everyday work."),
                     choice("gpt-6-luna", "6 Luna", "Fast and affordable model for easier tasks."),
                     choice("gpt-5.6-luna", "5.6 Luna", "Older fast and efficient model.")]
        #expect(DaemonCore.probeModel(in: codex)?.name == "6 Luna")
        // Nothing says it is small: keep the runtime's own default.
        #expect(DaemonCore.probeModel(in: [choice("big", "Big"), choice("bigger", "Bigger")]) == nil)
    }
}

/// Three rate limits within ten minutes, on one chat, is a limit that persists (065,
/// T013). The streak is the chat's, kept by the daemon per agent; this is its arithmetic.
@Suite("A chat's rate-limit streak")
struct RateLimitStreakTests {
    private let policy = RateLimitPolicy.standard
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    @Test func theThirdWithinTheWindowPersists() {
        var streak: [Date] = []
        var persists = false
        for minute in [0.0, 2, 4] {
            (streak, persists) = policy.streak(streak, adding: start.addingTimeInterval(minute * 60))
        }
        #expect(persists)
    }

    @Test func refusalsOutsideTheWindowDoNotCount() {
        let old = [start, start.addingTimeInterval(60)]
        let (streak, persists) = policy.streak(old, adding: start.addingTimeInterval(630))
        #expect(!persists)
        #expect(streak.count == 2, "the first fell out of the window")
    }

    @Test func twoAreNotYetAStreak() {
        #expect(!policy.streak([start], adding: start.addingTimeInterval(30)).persists)
    }
}
