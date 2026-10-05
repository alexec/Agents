import Foundation
import Testing
@testable import AgentsKitCore

/// Pairing ends, and says why in words (#84).
@Suite("Pairing attempts", .timeLimit(.minutes(1)))
struct PairingAttemptTests {
    @Test func anAnswerInTimeComesThrough() async throws {
        let value = try await PairingAttempt.run(within: .seconds(5)) { "paired" }
        #expect(value == "paired")
    }

    @Test func aControlPlaneThatNeverAnswersEndsAtTheDeadline() async throws {
        let gaveUp = ManagedAtomicFlag()
        let started = ContinuousClock.now
        await #expect(throws: PairingAttempt.NoAnswer.self) {
            try await PairingAttempt.run(within: .milliseconds(200)) {
                // A dial that hears nothing, cancellation included, for an hour.
                try? await Task.sleep(for: .seconds(3600))
                if Task.isCancelled { gaveUp.set() }
                return "too late"
            }
        }
        // Ended at its deadline, not when the work would have: the suite's minute is the
        // bound, not a few seconds a loaded Mac can overrun (#225).
        #expect(ContinuousClock.now - started < .seconds(3600))
        // The work is told it was given up on, so it does not save a pairing.
        await eventually("the work was cancelled") { gaveUp.isSet }
    }

    @Test func cancellingTheCallerCancelsTheWork() async throws {
        let gaveUp = ManagedAtomicFlag()
        let caller = Task {
            try await PairingAttempt.run(within: .seconds(30)) {
                try? await Task.sleep(for: .seconds(30))
                if Task.isCancelled { gaveUp.set() }
                return "too late"
            }
        }
        try await Task.sleep(for: .milliseconds(50))
        caller.cancel()
        await eventually("the work was cancelled") { gaveUp.isSet }
    }

    @Test func failuresAreSaidInWords() {
        let noAnswer = PairingAttempt.sentence(for: PairingAttempt.NoAnswer(), device: "this Mac")
        #expect(noAnswer.hasPrefix("The control plane didn’t answer."))
        #expect(noAnswer.contains("this Mac can reach it"))
        #expect(PairingAttempt.sentence(for: ControlCodeUse.Failure.noAnswer, device: "this Mac") == noAnswer)
        #expect(PairingAttempt.sentence(for: URLError(.cannotConnectToHost), device: "this iPhone")
            .hasPrefix("Couldn’t reach the control plane."))
        #expect(PairingAttempt.sentence(for: JSONRPCError(code: 1, message: "That code was used."), device: "this Mac")
            == "That code was used.")
        // Paired, and the disk would not keep it (#212): said as that, not as a code refused.
        let full = PairingAttempt.sentence(for: POSIXError(.ENOSPC), device: "this Mac")
        #expect(full.hasPrefix("This Mac is out of disk space, so the pairing could not be saved."))
        #expect(full.hasSuffix("The same code works until it runs out."))
        // Anything else is never Swift's description of the error.
        let other = PairingAttempt.sentence(for: ControlCodeUse.Failure("refused: unknown code"), device: "this Mac")
        #expect(!other.contains("refused"))
        #expect(other.contains("show a new one"))
    }
}
