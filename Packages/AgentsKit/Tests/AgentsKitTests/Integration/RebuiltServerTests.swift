import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

extension FakeSSHSuites {
    /// A server that comes back empty (043 US3): a new key at a known name, trusted again
    /// only on the person's word; and a wiped home, set up again without asking.
    @Suite("A rebuilt server")
    struct RebuiltServerTests {
        /// A key that is not the fixture's: the server as it was before the rebuild.
        private func oldKey(in folder: URL) async throws -> String {
            let path = folder.appendingPathComponent("old_key").path
            let keygen = SSHCommand(executable: URL(filePath: "/usr/bin/ssh-keygen"), name: "", controlPath: nil)
            _ = try await keygen.run(["-q", "-t", "ed25519", "-N", "", "-C", "", "-f", path])
            return try String(contentsOfFile: path + ".pub", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        @Test func theOldKeyIsForgottenOnlyForThisHostAndTheNewOneTrusted() async throws {
            let fake = try FakeSSH()
            defer { fake.tearDown() }
            let old = try await oldKey(in: fake.folder)
            let file = fake.folder.appendingPathComponent("known_hosts")
            try "other.example ssh-ed25519 AAAA\nfakebox \(old)\n".write(to: file, atomically: true, encoding: .utf8)
            let ssh = fake.command(knownHosts: file)
            let resolved = try await HostKeyCheck.resolve(ssh)

            let before = await HostKeyCheck.knownFingerprint(resolved)
            #expect(before?.hasPrefix("SHA256:") == true)
            let fetched = try await HostKeyCheck.fetch(ssh)
            #expect(fetched.fingerprint != before, "the rebuilt server has a new key")

            try await HostKeyCheck.forget(resolved)
            #expect(try await HostKeyCheck.isKnown(resolved) == false)
            try await HostKeyCheck.trust(fetched, into: resolved)
            #expect(await HostKeyCheck.knownFingerprint(resolved) == fetched.fingerprint)
            let text = try String(contentsOf: file, encoding: .utf8)
            #expect(text.contains("other.example ssh-ed25519 AAAA"), "other hosts are kept")
            #expect(!text.contains(old))
        }

        @Test func aWipedServerIsSetUpAgainWithoutAsking() async throws {
            let setup = try await ToolsetInstallTests.setUp()
            defer { Task { await ToolsetInstallTests.tearDown(setup) } }
            let server = try ToolsetInstallTests.connection(setup, wantsClaude: true)
            await server.connect()
            await server.disconnect()
            // The daemon first, by its own lock, then everything Agents put there.
            let lock = setup.fake.home.appendingPathComponent(".agents-server/root/daemon.lock")
            if let pid = Int32((try? String(contentsOf: lock, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "") { kill(pid, SIGTERM) }
            try await Task.sleep(for: .milliseconds(500))
            try FileManager.default.removeItem(at: setup.fake.home.appendingPathComponent(".agents-server"))

            await server.connect()
            let state = await server.state, claude = await server.claude
            await server.disconnect()
            #expect(state == .connected)
            #expect(claude == .ready(setup.tools.toolset.id))
        }
    }
}
