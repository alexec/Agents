import AgentsKit
import AgentsKitCore
@testable import ControlPlaneKit
import Foundation
import Testing

/// How `hosts/install` runs ssh, with a key and without one (#413).
@Suite("Install over ssh: the key is optional")
struct HostInstallTests {
    let knownHosts = URL(fileURLWithPath: "/tmp/agents-install-x/known_hosts")

    @Test func aGivenKeyIsTheOnlyOneTried() {
        let options = HostInstall.options(keyFile: URL(fileURLWithPath: "/tmp/agents-install-x/key"), knownHosts: knownHosts)
        #expect(options.starts(with: ["-i", "/tmp/agents-install-x/key", "-o", "IdentitiesOnly=yes", "-o", "IdentityAgent=none"]))
        #expect(options.contains("UserKnownHostsFile=/tmp/agents-install-x/known_hosts"))
        #expect(HostInstall.environment(keepAgent: false, from: ["SSH_AUTH_SOCK": "/tmp/agent", "HOME": "/Users/a"])
            == ["HOME": "/Users/a"])
    }

    @Test func withoutAKeySSHChoosesAsItWouldForThePerson() {
        let options = HostInstall.options(keyFile: nil, knownHosts: knownHosts)
        #expect(!options.contains("-i"))
        #expect(!options.contains { $0.hasPrefix("IdentitiesOnly") || $0.hasPrefix("IdentityAgent") })
        // The host key is still confirmed, and still kept out of the person's known_hosts.
        #expect(options == ["-o", "UserKnownHostsFile=/tmp/agents-install-x/known_hosts",
                            "-o", "GlobalKnownHostsFile=/dev/null", "-o", "StrictHostKeyChecking=yes"])
        #expect(HostInstall.environment(keepAgent: true, from: ["SSH_AUTH_SOCK": "/tmp/agent", "AGENTS_ROOT": "/r"])
            == ["SSH_AUTH_SOCK": "/tmp/agent"])
    }

    @Test func aRefusalSaysWhichKeysWereTried() {
        #expect(HostInstall.say(.loginRefused, keyGiven: true) == "The server refused that key.")
        #expect(HostInstall.say(.loginRefused, keyGiven: false).contains("every key ssh offered"))
        #expect(HostInstall.say(.keyLocked, keyGiven: false).contains("ssh-add"))
    }

    @Test func aRequestNeedNotCarryAKey() throws {
        let request = try JSONDecoder().decode(HostInstall.Request.self, from: Data(#"{"destination":"agents@devbox.lan"}"#.utf8))
        #expect(request.destination == "agents@devbox.lan")
        #expect(request.key == nil)
    }

    /// Against a real server this Mac's own ssh reaches (the devbox), with no key at all:
    /// the host key is shown, and once trusted, ssh logs in and reads the system. Only when
    /// `AGENTS_INSTALL_LIVE` names the destination, e.g. `agents@127.0.0.1:2222`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["AGENTS_INSTALL_LIVE"] != nil))
    func withoutAKeyTheMacsOwnSSHLogsIn() async throws {
        let destination = try #require(ProcessInfo.processInfo.environment["AGENTS_INSTALL_LIVE"])
        let codes = ControlCodes.forCommandLine(store: MemoryStore(), privateKey: ControlAgreement.generate().privateKey,
                                                url: "https://127.0.0.1:1", pin: nil, name: "live")
        // No servers folder: the install stops once ssh has logged in and read the system.
        let install = HostInstall(codes: codes, servers: FileManager.default.temporaryDirectory.appendingPathComponent("no-servers-\(UUID())"))
        let asked = try await install.run(["destination": .string(destination)])
        let fingerprint = try #require(asked["needsTrust"]?.stringValue)
        await #expect {
            _ = try await install.run(["destination": .string(destination), "trust": .string(fingerprint)])
        } throws: { error in
            let message = (error as? JSONRPCError)?.message ?? "\(error)"
            print("LIVE \(message)")
            return message.contains("which this control plane has no host for")
        }
    }
}
