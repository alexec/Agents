import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// 043 against a real bare Linux server: `agents-bare` from the test-servers skill (ssh, curl,
/// xz, git; no Node, no Claude, no sign-in), over real ssh, with the real Linux `agentsd` and
/// the real pinned toolset. Off unless `AGENTS_BARE=1`; start with `bare.sh rebuild`.
///
///     .claude/skills/test-servers/scripts/bare.sh rebuild
///     scripts/build-linux-agentsd.sh
///     AGENTS_BARE=1 swift test --filter BareServerLiveTests
///
/// The token is made up: what this proves is the install, the lend on demand, a start
/// that goes ahead once lent, and the refusal said as a refusal. A turn that answers needs
/// the person's own token, pasted into the window, and is the walk's.
@Suite("A bare server, live", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["AGENTS_BARE"] == "1"))
struct BareServerLiveTests {
    static let repo = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
    static let madeUp = Secret("sk-ant-oat01-BARELIVEMADEUP-0000")!

    /// The person's ssh, told to trust whatever key the box has and write it nowhere.
    private func ssh(in folder: URL) throws -> SSHCommand {
        let wrapper = folder.appendingPathComponent("ssh")
        try """
            #!/bin/sh
            exec /usr/bin/ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
              -o GlobalKnownHostsFile=/dev/null -o LogLevel=ERROR "$@"
            """.write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        return SSHCommand(executable: wrapper, name: "agents@127.0.0.1:2223",
                          controlPath: folder.appendingPathComponent("b.ctl"))
    }

    @Test func aBareServerGetsClaudeLendsOnDemandAndSaysARefusalIsOne() async throws {
        let folder = URL(filePath: "/tmp/bare-\(UUID().uuidString.prefix(6))", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let ssh = try ssh(in: folder)
        let binary = Self.repo.appendingPathComponent("App/Resources/servers/agentsd-linux-aarch64")
        let sha = try String(contentsOf: binary.appendingPathExtension("sha256"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let toolset = try Toolset.load(from: Self.repo.appendingPathComponent("App/Resources/toolsets/claude"))

        let box = LentBox()
        let server = ServerConnection(
            hostID: HostID(rawValue: "bare0001"), ssh: ssh, socket: folder.appendingPathComponent("b.sock"),
            installedBy: "BareServerLiveTests",
            binary: { _ in ServerBinary(file: binary, sha256: sha, version: "0.1.0+1") },
            toolset: { toolset }, wantsClaude: { true },
            offer: { DaemonAPI.CredentialsOffer(runtimes: ["claude"], ownSignInOnly: false) },
            lender: { wanted in await box.lend(wanted) })
        await box.set(server)

        let began = ContinuousClock.now
        await server.connect()
        let installed = ContinuousClock.now - began
        #expect(await server.state == .connected)
        #expect(await server.claude == .ready(toolset.id), "installed in \(installed)")

        _ = try await server.client.call(DaemonAPI.Method.projectsAdd,
                                         DaemonAPI.ProjectRequest(folder: URL(filePath: "/home/agents/src/hello")))
        let made = try await server.client.call(
            DaemonAPI.Method.agentsStart,
            DaemonAPI.StartRequest(runtimeID: "claude", cwd: URL(filePath: "/home/agents/src/hello"),
                                   prompt: "Reply with the single word pong.", requestID: UUID()))
        #expect(await box.asked == 1, "asked once, lent once, started once")
        let agentID = try #require(made.stringValue.flatMap(UUID.init(uuidString:)))

        var notes: [String] = []
        for _ in 0..<120 {
            let page = try await server.client.call(DaemonAPI.Method.agentsTranscript,
                                                    DaemonAPI.TranscriptRequest(agentID: agentID, limit: 200),
                                                    returning: TranscriptPage.self)
            notes = page.entries.compactMap { if case .runtimeNote(let t) = $0.kind { t } else { nil } }
            if notes.contains(where: { $0.contains("refused") || $0.contains("stopped answering") }) { break }
            try await Task.sleep(for: .milliseconds(500))
        }
        #expect(notes.contains("Claude refused the token in Settings. Replace it in Settings ▸ Servers."), "\(notes)")

        // Nowhere on the server's disk (FR-012).
        let grep = try await ssh.run(ssh.runArguments("grep -rlF BARELIVEMADEUP \"$HOME\" /tmp 2>/dev/null; true"))
        #expect(grep.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "\(grep.stdout)")
        await server.disconnect()
    }
}

/// Lends the made-up token on the connection that asked, and counts the asking.
private actor LentBox {
    private var server: ServerConnection?
    private(set) var asked = 0
    func set(_ server: ServerConnection) { self.server = server }
    func lend(_ wanted: DaemonAPI.CredentialWanted) async -> Bool {
        asked += 1
        return await server?.lend(wanted.runtime, BareServerLiveTests.madeUp) ?? false
    }
}
