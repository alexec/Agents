import Foundation
import Testing
@testable import AgentsKitCore

/// What 043 adds to a server's record, and that a `hosts.json` from before it still reads.
@Suite("A server's record after 043")
struct HostRecordTests {
    /// A host as 037 wrote it: today's encoding with every key 043 added taken out.
    static func from037() throws -> Data {
        var host = try ServerHost(sshName: "devbox")
        host.trustedFingerprint = "SHA256:abc"
        host.facts = ServerFacts(system: "Linux", architecture: .aarch64, home: "/home/agents", freeBytes: 1000,
                                 installedVersion: "0.1.0+1", installedSHA256: "ff", streamLocalForwarding: true)
        var hosts = HostList()
        try hosts.add(host)
        let added: Set<String> = ["ownSignInOnly", "knownProjects", "libc", "downloader", "toolsetID",
                                  "hasNpx", "hasOwnClaudeSignIn"]
        func strip(_ value: Any) -> Any {
            if let object = value as? [String: Any] {
                return object.filter { !added.contains($0.key) }.mapValues(strip)
            }
            if let array = value as? [Any] { return array.map(strip) }
            return value
        }
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(hosts))
        let stripped = try JSONSerialization.data(withJSONObject: strip(json))
        let text = String(decoding: stripped, as: UTF8.self)
        #expect(!added.contains { text.contains("\"\($0)\"") })
        return stripped
    }

    @Test func aHostsFileFrom037StillReads() throws {
        let hosts = try JSONDecoder().decode(HostList.self, from: Self.from037())
        let host = try #require(hosts.all.first)
        #expect(host.sshName == "devbox")
        #expect(host.ownSignInOnly == false)
        #expect(host.knownProjects.isEmpty)
        let facts = try #require(host.facts)
        #expect(facts.installedSHA256 == "ff")
        #expect(facts.libc == .unknown)
        #expect(facts.toolsetID == nil)
        #expect(facts.downloader == nil)
        #expect(!facts.hasNpx && !facts.hasOwnClaudeSignIn)
    }

    @Test func theNewFieldsSurviveARoundTrip() throws {
        var host = try ServerHost(sshName: "agents@127.0.0.1:2223")
        host.ownSignInOnly = true
        host.knownProjects = ["/home/agents/src/hello"]
        host.facts = ServerFacts(system: "Linux", architecture: .aarch64, home: "/home/agents", freeBytes: 1,
                                 installedVersion: nil, streamLocalForwarding: true,
                                 libc: .glibc(major: 2, minor: 36), downloader: "curl",
                                 toolsetID: "dcc7e847c9890e9d", hasNpx: false, hasOwnClaudeSignIn: true)
        let back = try JSONDecoder().decode(ServerHost.self, from: JSONEncoder().encode(host))
        #expect(back == host)
    }

    @Test(arguments: [
        ("ldd (Debian GLIBC 2.36-9+deb12u14) 2.36", Libc.glibc(major: 2, minor: 36)),
        ("ldd (GNU libc) 2.28", .glibc(major: 2, minor: 28)),
        ("ldd (Ubuntu GLIBC 2.39-0ubuntu8.4) 2.39", .glibc(major: 2, minor: 39)),
        ("musl libc (aarch64)", .musl),
        ("sh: ldd: not found", .unknown),
    ])
    func theCLibraryIsReadFromLdd(_ line: String, _ expected: Libc) {
        #expect(Libc(lddFirstLine: line) == expected)
    }

    @Test func claudeInstallsOnlyOnGlibc228OrLater() {
        func facts(_ libc: Libc) -> ServerFacts {
            ServerFacts(system: "Linux", architecture: .x86_64, home: "/h", freeBytes: 0,
                        installedVersion: nil, streamLocalForwarding: true, libc: libc)
        }
        #expect(facts(.glibc(major: 2, minor: 28)).canInstallClaude)
        #expect(facts(.glibc(major: 3, minor: 0)).canInstallClaude)
        #expect(!facts(.glibc(major: 2, minor: 17)).canInstallClaude)
        #expect(!facts(.musl).canInstallClaude)
        #expect(!facts(.unknown).canInstallClaude)
    }
}
