import Foundation
import Testing
@testable import AgentsKitCore

/// New Machine in one step (#5204): the sign-in New Machine asked for opens by itself once the
/// machine joins and its runtime is installed. The web page's machineSetup is tested with the
/// same cases.
@Suite("New Machine signs its runtime in once it joins")
struct MachineSetupTests {
    private func status(_ availability: RuntimeAvailability, signedIn: Bool? = false, relayed: Bool? = nil) -> RuntimeStatus {
        var status = RuntimeStatus(runtime: RuntimeCatalog.claude, availability: availability)
        status.signIn = signedIn.map { RuntimeStatus.SignIn(signedIn: $0, relayed: relayed) }
        return status
    }

    private let available = RuntimeAvailability.available(path: "/usr/bin/claude", supportsResume: true)

    @Test func itWaitsWhileTheRuntimeIsNotThereYet() {
        #expect(MachineSetups.step(runtimeID: "claude", runtimes: [], canSignIn: true) == .wait)
        #expect(MachineSetups.step(runtimeID: "claude", runtimes: [status(.installing(progress: nil))], canSignIn: true) == .wait)
        #expect(MachineSetups.step(runtimeID: "claude", runtimes: [status(.missing(lookedIn: []))], canSignIn: true) == .wait)
    }

    @Test func itOpensTheSignInWhenTheRuntimeIsNotSignedIn() {
        #expect(MachineSetups.step(runtimeID: "claude", runtimes: [status(available)], canSignIn: true)
                == .signIn(RuntimeCatalog.claude))
    }

    @Test func itOpensNothingWhenThereIsNothingToSignIn() {
        // Signed in already, or a Mac lends it its own sign-in.
        #expect(MachineSetups.step(runtimeID: "claude", runtimes: [status(available, signedIn: true)], canSignIn: true) == .done)
        #expect(MachineSetups.step(runtimeID: "claude", runtimes: [status(available, relayed: true)], canSignIn: true) == .done)
        // A machine that does not sign in from a client, or a runtime with no sign-in.
        #expect(MachineSetups.step(runtimeID: "claude", runtimes: [status(available)], canSignIn: false) == .done)
        #expect(MachineSetups.step(runtimeID: "claude", runtimes: [status(available, signedIn: nil)], canSignIn: true) == .done)
        #expect(MachineSetups.step(runtimeID: "claude", runtimes: [status(.installFailed(reason: "no"))], canSignIn: true) == .done)
    }

    @Test func itKeepsTheMachinesUntilTheyAreDoneOrTheWaitIsOver() {
        let made = Date(timeIntervalSince1970: 1_000)
        var setups = MachineSetups()
        setups.made("machine-3", signIn: "claude", at: made)
        setups.made("machine-4", signIn: nil, at: made)
        #expect(setups.joined(["machine-3", "machine-4", "devbox"], at: made).map(\.name) == ["machine-3"])
        #expect(setups.joined(["machine-3"], at: made.addingTimeInterval(MachineSetups.wait)).isEmpty)
        setups.done("machine-3")
        #expect(setups.joined(["machine-3"], at: made).isEmpty)
        setups.made("machine-5", signIn: "codex", at: made)
        setups.expire(at: made.addingTimeInterval(MachineSetups.wait + 1))
        #expect(setups.signIns.isEmpty)
    }
}
