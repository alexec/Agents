import Foundation
import Testing
@testable import AgentsKitCore

/// US3 of 052: a new chat about to start on a runtime that is out is told so first.
@Suite("Starting a chat on a runtime that is out")
struct StartingOnOutTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let claude = PoolEntry(runtimeID: "claude", payment: .allowance(label: nil))
    private let codex = PoolEntry(runtimeID: "codex", payment: .allowance(label: nil))
    private let copilot = PoolEntry(runtimeID: "copilot", payment: .allowance(label: nil))

    private func row(_ entry: PoolEntry, outUntil: Date? = nil, out: Bool = false, unusable: String? = nil) -> PoolStatus.Row {
        var state = AllowanceState(credentialKey: AllowanceState.credentialKey(for: entry), entryID: entry.id, since: now)
        if out { state.markOut(.allowanceSpent, until: outUntil, payment: entry.payment, now: now, from: .typedFailure) }
        return PoolStatus.Row(entry: entry, state: state, chats: 0, unusable: unusable)
    }

    @Test func itSaysUntilWhenAndOffersTheFirstThatCanBeUsed() {
        let status = PoolStatus(settings: PoolSettings(isOn: true, entries: [claude, codex, copilot]),
                                rows: [row(claude, outUntil: now.addingTimeInterval(3600), out: true),
                                       row(codex, unusable: "not signed in"), row(copilot)], at: now)
        let notice = status.startingOnOut("claude")
        #expect(notice?.sentence.hasPrefix("Claude is out. Its provider says it resets at ") == true)
        #expect(notice?.sentence.hasSuffix("; the app checks before using it again.") == true)
        #expect(notice?.instead == "copilot")
    }

    @Test func nothingWhenItIsNotOutOrNotInThePool() {
        let status = PoolStatus(settings: PoolSettings(isOn: true, entries: [claude, codex]),
                                rows: [row(claude), row(codex)], at: now)
        #expect(status.startingOnOut("claude") == nil)
        #expect(status.startingOnOut("grok") == nil)
    }

    @Test func noneToOfferWhenEveryoneIsOut() {
        let status = PoolStatus(settings: PoolSettings(isOn: true, entries: [claude, codex]),
                                rows: [row(claude, out: true), row(codex, out: true)], at: now)
        #expect(status.startingOnOut("claude")?.instead == nil)
        // No time from the provider: only when the app tries it again, never "until".
        let sentence = status.startingOnOut("claude")?.sentence
        #expect(sentence?.hasPrefix("Claude is out, so its first turn would be refused. It is tried again after ") == true)
    }
}
