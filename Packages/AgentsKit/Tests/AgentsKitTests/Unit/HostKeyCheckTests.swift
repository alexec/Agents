import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// Trusting a server's key the first time, and only after the person has seen it (037).
@Suite("Host keys", .serialized)
struct HostKeyCheckTests {
    private func knownHosts(_ fake: FakeSSH, _ contents: String = "") throws -> URL {
        let file = fake.folder.appendingPathComponent("known_hosts")
        try contents.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    private var fixtureKey: String {
        get throws { try String(contentsOf: FakeSSH.fixtures.appendingPathComponent("host_key.pub"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    @Test func theConfigIsReadWithoutConnecting() async throws {
        let fake = try FakeSSH()
        defer { fake.tearDown() }
        let file = try knownHosts(fake)
        let resolved = try await HostKeyCheck.resolve(fake.command(knownHosts: file))
        #expect(resolved.hostname == "fakebox")
        #expect(resolved.port == 22)
        #expect(resolved.knownHostsFiles == [file.path])
        #expect(resolved.hashKnownHosts == false)
    }

    @Test func aKeyAlreadyTrustedIsKnown() async throws {
        let fake = try FakeSSH()
        defer { fake.tearDown() }
        let file = try knownHosts(fake, "fakebox \(try fixtureKey)\n")
        let ssh = fake.command(knownHosts: file)
        #expect(try await HostKeyCheck.isKnown(HostKeyCheck.resolve(ssh)))
    }

    @Test func anUnknownKeyIsFetchedAndItsFingerprintShown() async throws {
        let fake = try FakeSSH()
        defer { fake.tearDown() }
        let file = try knownHosts(fake)
        let ssh = fake.command(knownHosts: file)
        let resolved = try await HostKeyCheck.resolve(ssh)
        #expect(try await HostKeyCheck.isKnown(resolved) == false)

        let fetched = try await HostKeyCheck.fetch(ssh)
        defer { HostKeyCheck.discard(fetched) }
        #expect(fetched.fingerprint.hasPrefix("SHA256:"))
        #expect(fetched.fingerprint.count > 40)
        #expect(try String(contentsOf: file, encoding: .utf8).isEmpty, "nothing trusted until the person says so")
    }

    @Test func trustingAppendsTheKeyAndThenItIsKnown() async throws {
        let fake = try FakeSSH()
        defer { fake.tearDown() }
        let file = try knownHosts(fake, "other.example ssh-ed25519 AAAA\n")
        let ssh = fake.command(knownHosts: file)
        let resolved = try await HostKeyCheck.resolve(ssh)
        let fetched = try await HostKeyCheck.fetch(ssh)
        try await HostKeyCheck.trust(fetched, into: resolved)
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text.hasPrefix("other.example ssh-ed25519 AAAA\n"), "what was there is kept")
        #expect(text.contains(try fixtureKey))
        #expect(try await HostKeyCheck.isKnown(resolved))
        #expect(!FileManager.default.fileExists(atPath: fetched.file.path), "the temporary file is gone")
    }

    @Test func trustingHashesWhenTheConfigSaysTo() async throws {
        let fake = try FakeSSH()
        defer { fake.tearDown() }
        let file = try knownHosts(fake)
        let ssh = fake.command(knownHosts: file)
        var resolved = try await HostKeyCheck.resolve(ssh)
        resolved.hashKnownHosts = true
        let fetched = try await HostKeyCheck.fetch(ssh)
        try await HostKeyCheck.trust(fetched, into: resolved)
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text.hasPrefix("|1|"), "hashed, so the file does not name the server")
        #expect(!text.contains("fakebox"))
        #expect(try await HostKeyCheck.isKnown(resolved))
    }

    @Test func cancellingLeavesNothing() async throws {
        let fake = try FakeSSH()
        defer { fake.tearDown() }
        let file = try knownHosts(fake)
        let fetched = try await HostKeyCheck.fetch(fake.command(knownHosts: file))
        HostKeyCheck.discard(fetched)
        #expect(!FileManager.default.fileExists(atPath: fetched.file.path))
        #expect(try String(contentsOf: file, encoding: .utf8).isEmpty)
    }

    @Test func anUnreachableHostFailsTheFetchWithItsName() async throws {
        let fake = try FakeSSH()
        defer { fake.tearDown() }
        await #expect(throws: HostProblem.unknownHost) {
            try await HostKeyCheck.fetch(fake.command(fail: "unknownHost"))
        }
    }
}
