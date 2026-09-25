import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// Every ssh command line the window builds, and what each ssh failure is called (037).
///
/// The command lines are matched exactly: they are contracts/ssh.md, and a flag that
/// drifts is a server that stops working without anything saying why.
@Suite("ssh command lines")
struct SSHCommandTests {
    private let ssh = SSHCommand(executable: URL(filePath: "/usr/bin/ssh"), name: "devbox",
                                 controlPath: URL(filePath: "/r/hosts/ab12cd34.ctl"))

    @Test func aPortAfterTheHostIsWrittenTheWaySSHReadsIt() {
        let withPort = SSHCommand(executable: URL(filePath: "/usr/bin/ssh"), name: "agents@127.0.0.1:2222",
                                  controlPath: nil)
        #expect(withPort.resolveArguments == ["-G", "--", "ssh://agents@127.0.0.1:2222"])
        #expect(withPort.runArguments("true").suffix(2) == ["ssh://agents@127.0.0.1:2222", "true"])
        let alias = SSHCommand(executable: URL(filePath: "/usr/bin/ssh"), name: "devbox", controlPath: nil)
        #expect(alias.destination == "devbox")
        let v6 = SSHCommand(executable: URL(filePath: "/usr/bin/ssh"), name: "fe80::1", controlPath: nil)
        #expect(v6.destination == "fe80::1", "an IPv6 address is not a port")
    }

    @Test func resolvingReadsTheConfigWithoutConnecting() {
        #expect(ssh.resolveArguments == ["-G", "--", "devbox"])
    }

    @Test func aMasterWithoutAForwardComesFirst() {
        #expect(ssh.masterArguments(forward: nil) == [
            "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
            "-M", "-N", "-S", "/r/hosts/ab12cd34.ctl",
            "-o", "ControlPersist=no", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3",
            "-o", "ExitOnForwardFailure=yes", "-o", "StreamLocalBindUnlink=yes",
            "--", "devbox"])
    }

    @Test func thenOneWithTheDaemonsSocketForwarded() {
        let args = ssh.masterArguments(forward: (local: "/r/hosts/ab12cd34.sock",
                                                 remote: "/home/alex/.agents-server/root/daemon.sock"))
        #expect(args.suffix(4) == ["-L", "/r/hosts/ab12cd34.sock:/home/alex/.agents-server/root/daemon.sock",
                                   "--", "devbox"])
    }

    @Test func aCommandGoesOverTheMaster() {
        #expect(ssh.runArguments("uname -sm") == [
            "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
            "-S", "/r/hosts/ab12cd34.ctl", "--", "devbox", "uname -sm"])
    }

    @Test func checkAndExitAskTheMaster() {
        #expect(ssh.controlArguments("check") == ["-S", "/r/hosts/ab12cd34.ctl", "-O", "check", "--", "devbox"])
        #expect(ssh.controlArguments("exit") == ["-S", "/r/hosts/ab12cd34.ctl", "-O", "exit", "--", "devbox"])
    }

    @Test func fetchingAKeyOffersNoCredentials() {
        let args = ssh.keyFetchArguments(knownHosts: URL(filePath: "/tmp/k"))
        #expect(args == ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
                         "-o", "StrictHostKeyChecking=accept-new", "-o", "UserKnownHostsFile=/tmp/k",
                         "-o", "GlobalKnownHostsFile=/dev/null", "-o", "PreferredAuthentications=none",
                         "--", "devbox", "true"])
    }

    @Test func theEnvironmentKeepsTheAgentAndDropsWhatCouldPromptOrLeak() {
        let env = SSHCommand.environment(from: [
            "PATH": "/usr/bin", "HOME": "/Users/a", "SSH_AUTH_SOCK": "/tmp/agent",
            "SSH_ASKPASS": "/bin/askpass", "DISPLAY": ":0", "CLAUDE_CODE_ENTRYPOINT": "x",
            "AGENTS_ROOT": "/r", "CLAUDECODE": "1"])
        #expect(env["SSH_AUTH_SOCK"] == "/tmp/agent")
        #expect(env["PATH"] == "/usr/bin")
        #expect(env["HOME"] == "/Users/a")
        for gone in ["SSH_ASKPASS", "DISPLAY", "CLAUDE_CODE_ENTRYPOINT", "AGENTS_ROOT", "CLAUDECODE"] {
            #expect(env[gone] == nil, "\(gone)")
        }
    }

    private func fixture(_ name: String) throws -> String {
        try String(contentsOf: FakeSSH.fixtures.appendingPathComponent("stderr/\(name).txt"), encoding: .utf8)
    }

    @Test(arguments: [
        ("unknownHost", HostProblem.unknownHost),
        ("hostKeyChanged", .hostKeyChanged),
        ("timedOut", .timedOut("connect")),
        ("refused", .timedOut("connect")),
        ("noStreamLocalForwarding", .noStreamLocalForwarding),
    ])
    func eachFailureIsNamed(_ name: String, _ problem: HostProblem) throws {
        #expect(SSHCommand.classify(status: 255, stderr: try fixture(name), agentHasKeys: true) == problem)
    }

    @Test func aRefusedLoginWithAnEmptyAgentIsALockedKey() throws {
        let stderr = try fixture("loginRefused")
        #expect(SSHCommand.classify(status: 255, stderr: stderr, agentHasKeys: false) == .keyLocked)
        #expect(SSHCommand.classify(status: 255, stderr: stderr, agentHasKeys: true) == .loginRefused)
    }

    @Test func aFullDiskIsSaidAsSuch() throws {
        #expect(SSHCommand.classify(status: 1, stderr: try fixture("diskFull"), agentHasKeys: true)
                == .diskFull(freeBytes: 0))
    }

    @Test func anythingElseKeepsItsLastThreeLines() {
        let problem = SSHCommand.classify(status: 1, stderr: "one\ntwo\nthree\nfour\n", agentHasKeys: true)
        #expect(problem == .installFailed("two\nthree\nfour"))
    }

    @Test func successIsNoProblem() {
        #expect(SSHCommand.classify(status: 0, stderr: "Warning: something harmless", agentHasKeys: true) == nil)
    }

    @Test func runningCapturesOutputAndStatus() async throws {
        let sh = SSHCommand(executable: URL(filePath: "/bin/sh"), name: "unused", controlPath: nil)
        let out = try await sh.run(["-c", "echo out; echo err >&2; exit 3"])
        #expect(out.status == 3)
        #expect(out.stdout == "out\n")
        #expect(out.stderr == "err\n")
    }

    @Test func runningFeedsAFileToStdin() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("stdin-\(UUID().uuidString)")
        try Data(repeating: 65, count: 3_000_000).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let sh = SSHCommand(executable: URL(filePath: "/bin/sh"), name: "unused", controlPath: nil)
        let out = try await sh.run(["-c", "wc -c | tr -d ' '"], stdin: file)
        #expect(out.stdout == "3000000\n")
    }
}
