import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// The idle rule is a pure function of three inputs, so it is tested as one. No pty, no
/// daemon, no clock to wait on.
@Suite("When a shell counts as idle")
struct ShellIdleTests {
    private let threshold: TimeInterval = 60 * 60
    private let now = Date(timeIntervalSince1970: 1_000_000)

    @Test func aBusyShellIsNeverIdle() {
        // The case the whole thing exists for: a build started before lunch. Nobody has
        // typed for hours and the shell must not be let go (FR-026, FR-027).
        let longAgo = now.addingTimeInterval(-threshold * 10)
        #expect(ShellSession.isIdle(isBusy: true, lastInputAt: longAgo, now: now, threshold: threshold) == false)
    }

    @Test func aQuietShellPastTheThresholdIsIdle() {
        let longAgo = now.addingTimeInterval(-threshold - 1)
        #expect(ShellSession.isIdle(isBusy: false, lastInputAt: longAgo, now: now, threshold: threshold))
    }

    @Test func aQuietShellInsideTheThresholdIsNot() {
        let recently = now.addingTimeInterval(-threshold + 1)
        #expect(ShellSession.isIdle(isBusy: false, lastInputAt: recently, now: now, threshold: threshold) == false)
    }

    @Test func exactlyTheThresholdCounts() {
        let onTheDot = now.addingTimeInterval(-threshold)
        #expect(ShellSession.isIdle(isBusy: false, lastInputAt: onTheDot, now: now, threshold: threshold))
    }

    @Test func aShellJustTypedIntoIsNotIdle() {
        #expect(ShellSession.isIdle(isBusy: false, lastInputAt: now, now: now, threshold: threshold) == false)
    }

    @Test func busyBeatsEveryOtherInput() {
        // Whatever the clock says, and whatever the threshold is.
        for seconds in [0.0, 1.0, threshold, threshold * 100] {
            let then = now.addingTimeInterval(-seconds)
            #expect(ShellSession.isIdle(isBusy: true, lastInputAt: then, now: now, threshold: threshold) == false)
        }
    }
}

@Suite("What a shell's state says")
struct ShellStateTests {
    @Test func onlyLiveIsLive() {
        #expect(ShellState.live.isLive)
        #expect(ShellState.exited(status: 0).isLive == false)
        #expect(ShellState.failed(reason: "no").isLive == false)
        #expect(ShellState.released(reason: "idle").isLive == false)
    }

    @Test func everyEndedStateCanBeRestarted() {
        // FR-024: the pane always offers a new shell once this one is over.
        #expect(ShellState.live.canRestart == false)
        #expect(ShellState.exited(status: 0).canRestart)
        #expect(ShellState.failed(reason: "no").canRestart)
        #expect(ShellState.released(reason: "idle").canRestart)
    }

    @Test func aCleanExitReadsDifferentlyFromAFailedOne() {
        #expect(ShellState.exited(status: 0).explanation == "The shell exited.")
        #expect(ShellState.exited(status: 2).explanation == "The shell exited with status 2.")
        #expect(ShellState.live.explanation == nil)
    }

    @Test func aReasonIsCarriedThroughACodingRoundTrip() throws {
        // The state crosses the socket, so it has to survive being encoded.
        let original = ShellState.released(reason: "let go after sitting idle")
        let data = try JSONEncoder().encode(original)
        let back = try JSONDecoder().decode(ShellState.self, from: data)
        #expect(back == original)
        #expect(back.explanation == "let go after sitting idle")
    }
}
