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
}
