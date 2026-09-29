import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// Choosing the next entry (052, FR-009, FR-016).
@Suite("Where a chat goes next")
struct PoolPlanTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let claude = PoolEntry(runtimeID: "claude", payment: .allowance(label: nil))
    private let copilot = PoolEntry(runtimeID: "copilot", payment: .allowance(label: nil))
    private let codex = PoolEntry(runtimeID: "codex", payment: .allowance(label: nil))
    private let codexKey = PoolEntry(runtimeID: "gemini", payment: .prepaid(amount: nil, expires: nil),
                                     credentialRef: CredentialKind.geminiAPIKey.rawValue)

    private var pool: PoolSettings { PoolSettings(isOn: true, entries: [claude, copilot, codex, codexKey]) }

    private func out(_ entry: PoolEntry, until: Date? = nil, since: Date? = nil) -> AllowanceState {
        let since = since ?? now
        var state = AllowanceState(credentialKey: AllowanceState.credentialKey(for: entry), entryID: entry.id, since: since)
        state.markOut(.allowanceSpent, until: until, payment: entry.payment, now: since, from: .typedFailure)
        return state
    }

    private func next(from current: PoolEntry, states: [AllowanceState] = [], tried: Set<String> = [],
                      off: Bool = false, unusable: Set<String> = [], pool: PoolSettings? = nil) -> PoolDecision {
        PoolPlan.next(current: current, pool: pool ?? self.pool, switchingOff: off,
                      states: Dictionary(uniqueKeysWithValues: states.map { ($0.credentialKey, $0) }),
                      tried: tried, unusable: { unusable.contains($0.runtimeID) ? "not signed in" : nil }, now: now)
    }

    @Test func theFirstUsableInOrder() {
        #expect(next(from: claude, states: [out(claude)]) == .switchTo(copilot))
    }

    @Test func outEntriesAndTriedOnesAreSkipped() {
        #expect(next(from: claude, states: [out(claude), out(copilot)]) == .switchTo(codex))
        #expect(next(from: copilot, tried: [AllowanceState.credentialKey(for: claude)]) == .switchTo(codex))
    }

    @Test func unusableEntriesAreSkipped() {
        #expect(next(from: claude, unusable: ["copilot"]) == .switchTo(codex))
    }

    @Test func theSameCredentialIsNeverTheNextOne() {
        let relayed = PoolEntry(runtimeID: "codex", payment: .allowance(label: "ChatGPT plan"))
        let pool = PoolSettings(isOn: true, entries: [codex, relayed, codexKey])
        #expect(next(from: codex, pool: pool) == .switchTo(codexKey))
    }

    @Test func everyoneOutGivesTheEarliestCheck() {
        // The next check, not the provider's reset: codex went out first, so is checked first.
        let reset = now.addingTimeInterval(600)
        let codexOut = now.addingTimeInterval(-3 * 3600)
        #expect(next(from: claude, states: [out(claude), out(copilot, until: reset),
                                            out(codex, since: codexOut), out(codexKey)])
                == .everyoneOut(earliest: codexOut.addingTimeInterval(4 * 3600)))
    }

    @Test func offWhenThePoolOrTheChatSaysSo() {
        #expect(next(from: claude, off: true) == .off)
        #expect(next(from: claude, pool: PoolSettings(isOn: false, entries: pool.entries)) == .off)
        #expect(next(from: claude, pool: PoolSettings(isOn: true, entries: [claude])) == .off)
    }

    @Test func aChatStartedOutsideThePoolMovesToTheFirstUsable() {
        let grok = PoolEntry(runtimeID: "grok", payment: .allowance(label: nil))
        #expect(next(from: grok) == .switchTo(claude))
    }
}
