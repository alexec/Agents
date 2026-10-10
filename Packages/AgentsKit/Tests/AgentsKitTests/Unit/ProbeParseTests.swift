import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// Reading what the probe prints (037 § 5, with 043's lines). The two samples are what
/// `agents-bare` and `agents-devbox` printed on 2026-09-25.
@Suite("Reading a server's probe")
struct ProbeParseTests {
    static let bare = """
        Linux aarch64
        /home/agents
        overlay           20464208 2061408  17337944      11% /

        default
        libc:ldd (Debian GLIBC 2.36-9+deb12u14) 2.36
        fetch:/usr/bin/curl
        toolset:none
        npx:no
        signin:none
        signin:none
        """

    static let devbox = """
        Linux aarch64
        /home/agents
        overlay           20464208 2061408  17337944      11% /
        {"version":"0.1.0+1","sha256":"e187","installedBy":"Mac","installedAt":"2026-09-25T22:22:05Z"}
        default
        libc:ldd (Debian GLIBC 2.36-9+deb12u14) 2.36
        fetch:/usr/bin/curl
        toolset:dcc7e847c9890e9d
        npx:yes
        signin:none
        signin:file
        """

    /// 047: a line per app toolset, so Codex's is known beside Claude's.
    @Test func everyAppToolsetIsReadByItsRuntime() throws {
        let text = Self.devbox.replacingOccurrences(of: "toolset:dcc7e847c9890e9d",
            with: "toolset:dcc7e847c9890e9d\ntoolset.claude:dcc7e847c9890e9d\ntoolset.codex:bfaa3f9fe30fc00f")
        let facts = try ServerInstaller.parseProbe(text)
        #expect(facts.toolsetIDs == ["claude": "dcc7e847c9890e9d", "codex": "bfaa3f9fe30fc00f"])
        #expect(facts.toolsetID(for: "codex") == "bfaa3f9fe30fc00f")
        #expect(facts.toolsetID(for: "claude") == "dcc7e847c9890e9d")
        #expect(try ServerInstaller.parseProbe(Self.bare).toolsetID(for: "codex") == nil)
    }


    @Test func aBareServerHasCurlAndNothingElse() throws {
        let facts = try ServerInstaller.parseProbe(Self.bare)
        #expect(facts.libc == .glibc(major: 2, minor: 36))
        #expect(facts.canInstallClaude)
        #expect(facts.downloader == "curl")
        #expect(facts.toolsetID == nil)
        #expect(!facts.hasNpx)
        #expect(!facts.hasOwnClaudeSignIn)
        #expect(facts.installedSHA256 == nil)
    }

    @Test func aSetUpServerHasItsToolsetNpxAndASignIn() throws {
        let facts = try ServerInstaller.parseProbe(Self.devbox)
        #expect(facts.toolsetID == "dcc7e847c9890e9d")
        #expect(facts.hasNpx)
        #expect(facts.hasOwnClaudeSignIn)
        #expect(facts.installedSHA256 == "e187")
    }

    @Test func aBannerFromTheLoginShellDoesNotMoveAnything() throws {
        let text = Self.bare.replacingOccurrences(of: "npx:no", with: "Welcome to devbox!\nLast login: today\nnpx:yes")
        let facts = try ServerInstaller.parseProbe(text)
        #expect(facts.hasNpx)
        #expect(facts.downloader == "curl")
    }

    @Test func muslNoDownloaderAndAnEnvironmentSignIn() throws {
        let text = Self.bare
            .replacingOccurrences(of: "libc:ldd (Debian GLIBC 2.36-9+deb12u14) 2.36", with: "libc:musl libc (aarch64)")
            .replacingOccurrences(of: "fetch:/usr/bin/curl", with: "fetch:none")
            .replacingOccurrences(of: "signin:none\nsignin:none", with: "signin:env\nsignin:none")
        let facts = try ServerInstaller.parseProbe(text)
        #expect(facts.libc == .musl)
        #expect(!facts.canInstallClaude)
        #expect(facts.downloader == nil)
        #expect(facts.hasOwnClaudeSignIn)
    }

    @Test func wgetIsNamedByItsName() throws {
        let facts = try ServerInstaller.parseProbe(Self.bare.replacingOccurrences(of: "/usr/bin/curl", with: "/usr/bin/wget"))
        #expect(facts.downloader == "wget")
    }

    @Test func aProbeFrom037WithoutTheNewLinesStillReads() throws {
        let old = Self.devbox.split(separator: "\n", omittingEmptySubsequences: false).prefix(5).joined(separator: "\n")
        let facts = try ServerInstaller.parseProbe(old)
        #expect(facts.libc == .unknown)
        #expect(facts.toolsetID == nil)
    }

    // MARK: Every toolset, and Gemini's own key (046)

    @Test func eachToolsetAndGeminisOwnKeyAreRead() throws {
        let text = Self.bare.replacingOccurrences(of: "toolset:none", with: """
            toolset:none
            toolset.claude:none
            toolset.codex:none
            toolset.gemini:ab59d3a4f9e41eb5
            """).replacingOccurrences(of: "npx:no", with: "npx:no\nsignin.gemini:env")
        let facts = try ServerInstaller.parseProbe(text)
        #expect(facts.toolsetID(for: "gemini") == "ab59d3a4f9e41eb5")
        #expect(facts.toolsetID(for: "claude") == nil)
        #expect(facts.toolsetID == nil)
        #expect(facts.hasOwnSignIn("gemini"))
        #expect(!facts.hasOwnSignIn("claude"))
    }

    @Test func theProbeAsksAboutEveryToolsetRuntime() {
        #expect(ServerInstaller.toolsetRuntimes.split(separator: " ").contains("gemini"))
        #expect(ServerInstaller.probeScript.contains("signin.gemini"))
        #expect(ServerInstaller.toolsetRuntimes.split(separator: " ").contains("codex"))
        #expect(ServerInstaller.probeScript.contains("signin.codex"))
    }

    /// Codex's own sign-in on a server is the file its own `codex login` saved (047).
    @Test func codexsOwnSignInIsItsSavedFile() throws {
        let with = try ServerInstaller.parseProbe(Self.bare + "\nsignin.codex:file")
        #expect(with.hasOwnSignIn("codex"))
        let without = try ServerInstaller.parseProbe(Self.bare + "\nsignin.codex:none")
        #expect(!without.hasOwnSignIn("codex"))
    }

    /// #514: an ssh that never got in says why, not an empty `installFailed("")`.
    @Test func anSSHThatFailsSaysWhyNotAnEmptyAnswer() async throws {
        #expect(throws: HostProblem.installFailed("The server sent nothing back.")) { try ServerInstaller.parseProbe("") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let fake = folder.appendingPathComponent("ssh")
        try "#!/bin/sh\necho 'Host key verification failed.' >&2\nexit 255\n".write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        let installer = ServerInstaller(ssh: SSHCommand(executable: fake, name: "cws.devstack", controlPath: nil))
        await #expect(throws: HostProblem.hostKeyChanged) { try await installer.probe() }
    }
}
