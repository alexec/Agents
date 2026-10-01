import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// What 043 adds to a server's record. A `hosts.json` from before it is past the cut-off
/// (#58): it does not read, and is set aside rather than written over.
@Suite("A server's record after 043")
struct HostRecordTests {
    /// A host as 037 wrote it: today's encoding with every key 043 added taken out.
    static func from037(keeping kept: Set<String> = []) throws -> Data {
        var host = try ServerHost(sshName: "devbox")
        host.trustedFingerprint = "SHA256:abc"
        host.facts = ServerFacts(system: "Linux", architecture: .aarch64, home: "/home/agents", freeBytes: 1000,
                                 installedVersion: "0.1.0+1", installedSHA256: "ff", streamLocalForwarding: true)
        var hosts = HostList()
        try hosts.add(host)
        let added = Set(["ownSignInOnly", "knownProjects", "libc", "downloader", "toolsetID",
                         "hasNpx", "hasOwnClaudeSignIn"]).subtracting(kept)
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

    @Test func aHostsFileFrom037DoesNotRead() throws {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(HostList.self, from: Self.from037())
        }
    }

    @Test func anUnreadableHostsFileIsSetAsideNotWrittenOver() throws {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "HostRecordTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "hosts.json")
        let old = try Self.from037()
        try old.write(to: file)

        #expect(HostStore(file: file).load().all.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: file.path), "moved, so a save cannot write over it")
        let aside = try #require(try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .first { $0.hasPrefix("hosts.json.unreadable-") })
        #expect(try Data(contentsOf: folder.appending(path: aside)) == old)
    }

    /// Facts are asked again on every connect: facts this build cannot read cost the
    /// facts, never the server.
    @Test func factsFromBefore043CostOnlyTheFacts() throws {
        let hosts = try JSONDecoder().decode(HostList.self,
                                             from: Self.from037(keeping: ["ownSignInOnly", "knownProjects"]))
        let host = try #require(hosts.all.first)
        #expect(host.sshName == "devbox")
        #expect(host.facts == nil)
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
