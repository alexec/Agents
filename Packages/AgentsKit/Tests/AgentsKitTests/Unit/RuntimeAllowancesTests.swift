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
        let sentence = rows.startingOnOut("claude")
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

/// What a chooser makes of a runtime's row, on the Mac and on the phone alike: which
/// run it belongs in, and what it says under the name. Both choosers ask the same
/// questions of the same numbers, so the answers live here once (065).
@Suite("A chooser reading what each runtime's allowance says")
struct RuntimeChooserAllowanceTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func row(_ key: String, out: Bool = false, rateLimitedUntil: Date? = nil) -> RuntimeAllowances.Row {
        var state = AllowanceState(credentialKey: key, entryID: UUID(), since: now)
        if out { state.markOut(.allowanceSpent, until: now.addingTimeInterval(3600), payment: .allowance(label: nil), now: now, from: .typedFailure) }
        if let rateLimitedUntil { state.rateLimited(now: now, retryAt: rateLimitedUntil) }
        return RuntimeAllowances.Row(credentialKey: key, state: state)
    }

    @Test func aSpentPlanPutsTheRuntimeInTheOutRun() {
        let allowances = RuntimeAllowances(rows: [row("claude:sign-in", out: true), row("grok:sign-in")], at: now)
        #expect(allowances.isOut("claude"))
        #expect(!allowances.isOut("grok"))
        #expect(allowances.isOut("cursor") == false, "a runtime nothing has happened to is not out")
    }

    @Test func oneCredentialOutIsEnoughToPutTheRuntimeInTheOutRun() {
        let allowances = RuntimeAllowances(rows: [row("claude:sign-in", out: true),
                                                  row("claude:apiKey", out: true)], at: now)
        #expect(allowances.isOut("claude"))
    }

    @Test func anOutRuntimeSaysWhatIsWrongWithItUnderTheName() {
        let allowances = RuntimeAllowances(rows: [row("claude:sign-in", out: true)], at: now)
        #expect(allowances.note(for: "claude")?.hasPrefix("Out · reset ") == true)
        #expect(allowances.note(for: "grok") == nil)
    }

    /// A rate limit is a throttle, not a spent plan: the runtime can still take a turn,
    /// so it stays in the available run, but it is not nothing to say.
    @Test func aRateLimitIsNeitherOutNorSilent() {
        let until = now.addingTimeInterval(1800)
        let allowances = RuntimeAllowances(rows: [row("copilot:sign-in", rateLimitedUntil: until)], at: now)
        #expect(!allowances.isOut("copilot"))
        let note = allowances.availableNote(for: "copilot")
        #expect(note?.contains("Rate limited") == true)
        #expect(allowances.availableNote(for: "grok") == nil)
    }

    /// A rate limit that has run out is a reading, not a change, and must not go on
    /// claiming to be one.
    @Test func aRateLimitThatHasRunOutSaysNothing() {
        let until = now.addingTimeInterval(-1)
        let allowances = RuntimeAllowances(rows: [row("copilot:sign-in", rateLimitedUntil: until)], at: now)
        #expect(allowances.availableNote(for: "copilot") == nil)
        #expect(!allowances.isOut("copilot"))
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

/// The sidebar's Runtimes row (#379): working out of installed, and a dot only when none work.
@Suite("The Runtimes row's count")
struct RuntimeTallyTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func status(_ id: String, _ availability: RuntimeAvailability) -> RuntimeStatus {
        RuntimeStatus(runtime: RuntimeCatalog.runtime(id: id) ?? RuntimeCatalog.claude, availability: availability)
    }

    private var available: RuntimeAvailability { .available(path: "/x", supportsResume: true) }

    private func allowances(out ids: [String]) -> RuntimeAllowances {
        RuntimeAllowances(rows: ids.map { id in
            var state = AllowanceState(credentialKey: "\(id):sign-in", entryID: UUID(), since: now)
            state.markOut(.allowanceSpent, until: nil, payment: .allowance(label: nil), now: now, from: .typedFailure)
            return RuntimeAllowances.Row(credentialKey: "\(id):sign-in", state: state)
        }, at: now)
    }

    @Test func notYetListedIsNotNone() {
        #expect(RuntimeTally([], allowances: nil) == nil)
    }

    @Test func oneOutOfThreeIsTwoWorkingAndNoDot() throws {
        let tally = try #require(RuntimeTally([status("claude", available), status("codex", available),
                                               status("grok", available)], allowances: allowances(out: ["grok"])))
        #expect(tally.words == "2/3")
        #expect(!tally.noneWorking)
    }

    @Test func notInstalledIsNotCountedButSignedOutIs() throws {
        let tally = try #require(RuntimeTally([status("claude", available),
                                               status("codex", .needsSignIn(authMethods: [], fixCommand: nil)),
                                               status("grok", .failed(reason: "no")),
                                               status("gemini", .missing(lookedIn: [])),
                                               status("cursor", .installing(progress: nil)),
                                               status("copilot", .installFailed(reason: "no"))], allowances: nil))
        #expect(tally.words == "1/3")
    }

    @Test func noneWorkingIsTheDot() throws {
        var out = status("claude", available)
        out.isOut = true
        let tally = try #require(RuntimeTally([out, status("codex", .needsSignIn(authMethods: [], fixCommand: nil))],
                                              allowances: nil))
        #expect(tally.words == "0/2")
        #expect(tally.noneWorking)
    }
}
