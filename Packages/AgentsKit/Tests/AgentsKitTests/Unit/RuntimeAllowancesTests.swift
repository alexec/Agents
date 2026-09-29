import Foundation
import Testing
@testable import AgentsKitCore

/// What the prompt bar says of a runtime that is out (065, contracts/runtime-state.md):
/// a warning and nothing else, with no other runtime offered.
@Suite("Every runtime's state, as the window reads it")
struct RuntimeAllowancesTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func row(_ key: String, out: Bool = false, until: Date? = nil) -> RuntimeAllowances.Row {
        var state = AllowanceState(credentialKey: key, entryID: UUID(), since: now)
        if out { state.markOut(.allowanceSpent, until: until, payment: .allowance(label: nil), now: now, from: .typedFailure) }
        return RuntimeAllowances.Row(credentialKey: key, state: state)
    }

    @Test func anOutRuntimeIsWarnedAboutWithTheProvidersTime() {
        let rows = RuntimeAllowances(rows: [row("claude:sign-in", out: true, until: now.addingTimeInterval(3600)),
                                            row("codex:sign-in")], at: now)
        let sentence = try? #require(rows.startingOnOut("claude"))
        #expect(sentence?.hasPrefix("Claude is out. Its provider says it resets at ") == true)
        #expect(sentence?.contains("Codex") == false, "no other runtime is offered")
    }

    @Test func withNoProviderTimeItSaysWhenTheAppChecks() {
        let rows = RuntimeAllowances(rows: [row("claude:sign-in", out: true)], at: now)
        #expect(rows.startingOnOut("claude")?.hasPrefix("Claude is out. The app checks it again at ") == true)
    }

    @Test func anAvailableOrUnknownRuntimeSaysNothing() {
        let rows = RuntimeAllowances(rows: [row("claude:sign-in")], at: now)
        #expect(rows.startingOnOut("claude") == nil)
        #expect(rows.startingOnOut("grok") == nil)
        #expect(!rows.anyOut)
    }

    @Test func aKeyedRowKnowsItsRuntime() {
        #expect(row("gemini:geminiAPIKey").runtimeID == "gemini")
        #expect(AllowanceState.runtimeID(of: "claude:sign-in") == "claude")
    }
}

/// Where a chat whose allowance ran out sits in the list (065, US2 scenario 2, R7).
@Suite("A spent allowance in the list")
struct SpentAllowanceGroupTests {
    @Test func itIsPausedNotNeedsYouNorWaiting() {
        let group = AgentGroup(for: .stopped, wantsEyes: false, report: nil, outcomeAsked: false,
                               parked: false, endedReason: .allowanceSpent)
        #expect(group == .stopped)
        #expect(group.title == "Paused")
        #expect(EndedReason.allowanceSpent.summary == "Its allowance ran out")
    }

    @Test func itIsDrawnWithTheStopMarkNotTheNeedsYouMark() {
        let shape = StatusShape(state: .stopped, outcome: nil, isWaiting: false, isComingBack: false,
                                endedReason: .allowanceSpent)
        #expect(shape == .stopped)
        #expect(!shape.wantsAPerson)
    }

    @Test func aRateLimitThatPersistedStillNeedsYou() {
        let group = AgentGroup(for: .stopped, wantsEyes: false, report: nil, outcomeAsked: false,
                               parked: false, endedReason: .rateLimited)
        #expect(group == .needsAttention)
    }
}
