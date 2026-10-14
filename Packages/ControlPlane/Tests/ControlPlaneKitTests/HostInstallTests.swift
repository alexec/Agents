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
                            "-o", "GlobalKnownHostsFile=/dev/null", "-o", "StrictHostKeyChecking=yes",
                            "-o", "LogLevel=error"])
        #expect(HostInstall.environment(keepAgent: true, from: ["SSH_AUTH_SOCK": "/tmp/agent", "AGENTS_ROOT": "/r"])
            == ["SSH_AUTH_SOCK": "/tmp/agent"])
    }

    /// #964: gh's codespace entry says `LogLevel quiet`, which hid "Host key verification
    /// failed"; ssh takes the command line's over the config's.
    @Test func sshsErrorsAreSaidOverAQuietConfig() async throws {
        let config = FileManager.default.temporaryDirectory.appendingPathComponent("agents-quiet-\(UUID().uuidString)")
        try "Host cs.*\n  LogLevel quiet\n  StrictHostKeyChecking no\n  UserKnownHostsFile /dev/null\n"
            .write(to: config, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: config) }
        let ssh = SSHCommand(executable: SSHCommand.system, name: "cs.w857.main", controlPath: nil)
        let resolved = try await ssh.run(["-F", config.path] + HostInstall.options(keyFile: nil, knownHosts: nil)
                                         + ssh.resolveArguments)
        #expect(resolved.status == 0, "\(resolved.stderr)")
        #expect(resolved.stdout.split(whereSeparator: \.isNewline).contains("loglevel ERROR"))
        #expect(resolved.stdout.split(whereSeparator: \.isNewline).contains("stricthostkeychecking true"))
    }

    @Test func aRefusalSaysWhichKeysWereTried() {
        #expect(HostInstall.say(.loginRefused, keyGiven: true) == "The server refused that key.")
        #expect(HostInstall.say(.loginRefused, keyGiven: false).contains("every key ssh offered"))
        #expect(HostInstall.say(.keyLocked, keyGiven: false).contains("ssh-add"))
    }

    /// #514: a generated config's `UserKnownHostsFile /dev/null` is replaced by ssh's own
    /// files, so `StrictHostKeyChecking=yes` checks the person's known_hosts; real files stay.
    @Test func aKnownHostsOfDevNullIsTheDefaultFilesInstead() {
        let devNull = "hostname 10.0.0.5\nuserknownhostsfile /dev/null\nstricthostkeychecking false\n"
        #expect(HostInstall.knownHostsOverride(resolved: devNull)
            == ["-o", "UserKnownHostsFile=~/.ssh/known_hosts ~/.ssh/known_hosts2"])
        #expect(HostInstall.knownHostsOverride(resolved: "userknownhostsfile /Users/a/.ssh/known_hosts /Users/a/.ssh/known_hosts2\n").isEmpty)
        #expect(HostInstall.knownHostsOverride(resolved: "hostname devbox\n").isEmpty)
    }

    @Test func aFailureIsASentence() {
        #expect(HostInstall.say(.hostKeyChanged, keyGiven: false).contains("known_hosts"))
        #expect(HostInstall.say(.installFailed(""), keyGiven: false) == "ssh failed without saying why.")
        #expect(HostInstall.say(.installFailed("kex_exchange_identification: closed"), keyGiven: false)
            == "kex_exchange_identification: closed")
        #expect(!HostInstall.say(.timedOut("connect"), keyGiven: false).contains("timedOut"))
    }

    @Test func aRequestNeedNotCarryAKey() throws {
        let request = try JSONDecoder().decode(HostInstall.Request.self, from: Data(#"{"destination":"agents@devbox.lan"}"#.utf8))
        #expect(request.destination == "agents@devbox.lan")
        #expect(request.key == nil)
    }

    /// #610: whether to tunnel is the sheet's to say; left out, a bastion decides.
    @Test func aRequestMaySayWhetherToTunnel() throws {
        let asked = try JSONDecoder().decode(HostInstall.Request.self, from: Data(#"{"destination":"ws","tunnel":true}"#.utf8))
        #expect(asked.tunnel == true)
        let left = try JSONDecoder().decode(HostInstall.Request.self, from: Data(#"{"destination":"ws"}"#.utf8))
        #expect(left.tunnel == nil)
    }

    @Test func anUnknownKeyIsNotAChangedOne() {
        #expect(HostInstall.say(.hostKeyUnknown, keyGiven: false).contains("isn’t in your known_hosts"))
        #expect(HostInstall.say(.hostKeyChanged, keyGiven: false).contains("has changed"))
    }
}
