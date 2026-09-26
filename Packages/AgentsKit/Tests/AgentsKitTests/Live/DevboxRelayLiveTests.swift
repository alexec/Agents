#if canImport(Network) && canImport(Security)
import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// 056 against agents-devbox (the test-servers skill), which has Claude signed in on its own:
/// the Mac's own Claude sign-in relayed through the same `ServerConnection` and relay the
/// window uses, with no window. Off unless `AGENTS_DEVBOX=1`. Reads this Mac's Claude sign-in
/// (never writes it) and spends a few tokens of its plan.
///
///     .agents/skills/test-servers/scripts/devbox.sh up
///     docker exec -u root agents-devbox useradd -m other      # a second account, once
///     scripts/build-linux-agentsd.sh
///     AGENTS_DEVBOX=1 swift test --filter DevboxRelayLiveTests
@Suite("The Mac's Claude sign-in on agents-devbox, live", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["AGENTS_DEVBOX"] == "1"))
struct DevboxRelayLiveTests {
    static let repo = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var all: [String] = []
        func add(_ line: String) { lock.withLock { all.append(line) } }
        var lines: [String] { lock.withLock { all } }
    }

    func ssh(in folder: URL) throws -> SSHCommand {
        let wrapper = folder.appendingPathComponent("ssh")
        try """
            #!/bin/sh
            exec /usr/bin/ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
              -o GlobalKnownHostsFile=/dev/null -o LogLevel=ERROR "$@"
            """.write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        return SSHCommand(executable: wrapper, name: "agents@127.0.0.1:2222",
                          controlPath: folder.appendingPathComponent("d.ctl"))
    }

    /// A connection as the window makes one, relaying this Mac's Claude sign-in unless the
    /// server is "own sign-in only" (as `HostSet.relayFor` does).
    func connect(ownSignInOnly: Bool, folder: URL, log: Lines) async throws -> (ServerConnection, MacSignInRelay) {
        let binary = Self.repo.appendingPathComponent("App/Resources/servers/agentsd-linux-aarch64")
        let sha = try String(contentsOf: binary.appendingPathExtension("sha256"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let toolset = try Toolset.load(from: Self.repo.appendingPathComponent("App/Resources/toolsets/claude"))
        let policy = try #require(ToolPolicyCatalog.claude.relay)
        let signIn = ClaudeKeychainSignIn(service: "Claude Code-credentials")
        try #require(signIn.isSignedIn, "Claude on this Mac must be signed in with a Claude account")
        let relay = MacSignInRelay(relay: policy, signIn: signIn,
                                   certificates: RelayCertificates(folder: folder.appendingPathComponent("relay")),
                                   log: { log.add($0) })
        let port = try await relay.start()
        let grant = ServerConnection.RelayGrant(runtime: "claude", localPort: port,
                                                caCertificate: try relay.certificates.caPEM(),
                                                standIn: try signIn.standIn())
        let server = ServerConnection(
            hostID: HostID(rawValue: "devbox56"), ssh: try ssh(in: folder), socket: folder.appendingPathComponent("d.sock"),
            installedBy: "DevboxRelayLiveTests",
            binary: { _ in ServerBinary(file: binary, sha256: sha, version: "0.1.0+1") },
            toolset: { toolset }, wantsClaude: { true },
            offer: { DaemonAPI.CredentialsOffer(runtimes: [], ownSignInOnly: ownSignInOnly) },
            relay: { ownSignInOnly ? [] : [grant] })
        await server.connect()
        #expect(await server.state == .connected)
        return (server, relay)
    }

    /// Start Claude in ~/src/hello and wait for its first reply to be finished.
    func turn(_ server: ServerConnection) async throws -> UUID {
        _ = try await server.client.call(DaemonAPI.Method.projectsAdd,
                                         DaemonAPI.ProjectRequest(folder: URL(filePath: "/home/agents/src/hello")))
        let made = try await server.client.call(
            DaemonAPI.Method.agentsStart,
            DaemonAPI.StartRequest(runtimeID: "claude", cwd: URL(filePath: "/home/agents/src/hello"),
                                   prompt: "Reply with the single word pong.", requestID: UUID()))
        let id = try #require(made.stringValue.flatMap(UUID.init(uuidString:)))
        for _ in 0..<120 {
            let page = try await server.client.call(DaemonAPI.Method.agentsTranscript,
                                                    DaemonAPI.TranscriptRequest(agentID: id, limit: 200),
                                                    returning: TranscriptPage.self)
            let text = page.entries.compactMap { entry -> String? in
                if case .agentMessage(_, let t, _) = entry.kind { return t } else { return nil }
            }.joined()
            if text.lowercased().contains("pong") { return id }
            try await Task.sleep(for: .milliseconds(500))
        }
        let page = try await server.client.call(DaemonAPI.Method.agentsTranscript,
                                                DaemonAPI.TranscriptRequest(agentID: id, limit: 200),
                                                returning: TranscriptPage.self)
        Issue.record("no reply: \(page.entries.suffix(6).map { "\($0.kind)".prefix(160) })")
        return id
    }

    /// D7 and US5: the Mac's sign-in is used even though the devbox has its own, and the
    /// gate refuses another account on the same server.
    @Test func theMacsSignInBeatsTheServersAndNobodyElseCanUseIt() async throws {
        let folder = URL(filePath: "/tmp/dvb-\(UUID().uuidString.prefix(6))", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = Lines()
        let (server, relay) = try await connect(ownSignInOnly: false, folder: folder, log: log)
        defer { relay.stop() }

        _ = try await turn(server)
        #expect(log.lines.contains { $0.contains("POST /v1/messages -> 200") }, "\(log.lines)")

        // The gate's port, from the server's own log; then a request from uid `other`.
        let ssh = try ssh(in: folder)
        let port = try await ssh.run(ssh.runArguments(
            "grep -o 'relay offered for claude on port [0-9]*' ~/.agents-server/root/daemon.log | tail -1 | grep -o '[0-9]*$'"))
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(!port.isEmpty)
        let before = log.lines.count
        let stranger = Process()
        stranger.executableURL = URL(filePath: "/opt/homebrew/bin/docker")
        stranger.arguments = ["exec", "-u", "other", "agents-devbox", "curl", "-sk", "-m", "10", "-o", "/dev/null",
                              "-w", "%{http_code}", "-X", "POST", "https://127.0.0.1:\(port)/v1/messages"]
        let out = Pipe()
        stranger.standardOutput = out
        try stranger.run()
        stranger.waitUntilExit()
        let code = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(code == "000", "the stranger got an HTTP answer: \(code)")
        #expect(log.lines.count == before, "the stranger's request reached the Mac: \(log.lines.suffix(3))")
        let refused = try await ssh.run(ssh.runArguments("grep -c 'relay gate: refused' ~/.agents-server/root/daemon.log || true"))
        #expect((Int(refused.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) > 0)
        await server.disconnect()
    }

    /// D6: "own sign-in only" relays nothing, and the devbox's own Claude sign-in answers.
    @Test func ownSignInOnlyRelaysNothing() async throws {
        let folder = URL(filePath: "/tmp/dvb-\(UUID().uuidString.prefix(6))", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = Lines()
        let (server, relay) = try await connect(ownSignInOnly: true, folder: folder, log: log)
        defer { relay.stop() }
        _ = try await turn(server)
        #expect(log.lines.isEmpty, "\(log.lines)")
        await server.disconnect()
    }
}
#endif
