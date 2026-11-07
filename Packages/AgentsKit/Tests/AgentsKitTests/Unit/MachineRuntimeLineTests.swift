import Foundation
import Testing
@testable import AgentsKitCore

/// A runtime's line on a machine's page (#3629): installed or not, and signed in where the
/// machine says. The web page's machineRuntimeLine is tested with the same cases.
@Suite("A runtime's line on a machine's page")
struct MachineRuntimeLineTests {
    private func status(_ availability: RuntimeAvailability, signIn: RuntimeStatus.SignIn? = nil,
                        outdated: Bool = false, install: RuntimeInstall? = .toolset(runtimeID: "codex")) -> RuntimeStatus {
        var status = RuntimeStatus(runtime: Runtime(id: "codex", name: "Codex", executable: "codex-acp", arguments: [],
                                                    install: install),
                                   availability: availability, outdated: outdated)
        status.signIn = signIn
        return status
    }

    @Test func installedOnAMacSaysOnlyThat() {
        #expect(status(.available(path: "/p", supportsResume: true)).machineLine == "Installed")
    }

    @Test func aServerSaysWhetherItIsSignedIn() {
        let path = RuntimeAvailability.available(path: "/p", supportsResume: true)
        #expect(status(path, signIn: .init(signedIn: true)).machineLine == "Installed · signed in")
        #expect(status(path, signIn: .init(signedIn: false)).machineLine == "Installed · not signed in")
        #expect(status(path, signIn: .init(signedIn: false, relayed: true)).machineLine
                == "Installed · uses the Mac’s sign-in")
    }

    @Test func eachOtherStateHasItsWords() {
        #expect(status(.needsSignIn(authMethods: [], fixCommand: nil)).machineLine == "Installed · not signed in")
        #expect(status(.missing(lookedIn: [])).machineLine == "Not installed")
        #expect(status(.installing(progress: nil)).machineLine == "Installing…")
        #expect(status(.installing(progress: "Downloading")).machineLine == "Installing: Downloading")
        #expect(status(.installFailed(reason: "No network.")).machineLine == "Install failed: No network.")
        #expect(status(.available(path: "/p", supportsResume: true), outdated: true).machineLine
                == "Installed · an update is out")
    }

    @Test func itSaysTheVersionWhereTheMachineReadOne() {
        let path = RuntimeAvailability.available(path: "/p", supportsResume: true)
        var mac = status(path)
        mac.version = "2.1.4"
        #expect(mac.machineLine == "Installed 2.1.4")
        var server = status(path, signIn: .init(signedIn: true))
        server.version = "2.1.4"
        #expect(server.machineLine == "Installed 2.1.4 · signed in")
        var old = status(path, outdated: true)
        old.version = "2.5.0"
        #expect(old.machineLine == "Installed 2.5.0 · an update is out")
    }

    @Test func installIsOfferedOnlyForAMissingOneWithARecipe() {
        #expect(status(.missing(lookedIn: [])).offersInstall)
        #expect(status(.installFailed(reason: "x")).offersInstall)
        #expect(!status(.missing(lookedIn: []), install: nil).offersInstall)
        #expect(!status(.available(path: "/p", supportsResume: true)).offersInstall)
    }
}
