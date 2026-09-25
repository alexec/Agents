import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

extension FakeSSHSuites {
    /// A server from nothing to answering, and what happens when it goes (037).
    @Suite("Connecting to a server")
    struct ServerConnectionTests {
        private func connection(_ fake: FakeSSH, uname: String? = nil, fail: String? = nil,
                                version: String = "0.1.0+1") throws -> ServerConnection {
            let agentsd = try #require(ServerLinkTests.agentsd)
            let ssh = fake.command(fail: fail, uname: uname)
            return ServerConnection(hostID: HostID(rawValue: "fk000001"), ssh: ssh,
                                    socket: fake.hosts.appendingPathComponent("fk000001.sock"),
                                    installedBy: "test") { _ in
                ServerBinary(file: agentsd, sha256: (try? await ServerInstaller.sha256(of: agentsd)) ?? "",
                             version: version)
            }
        }

        @Test func aNewServerIsSetUpAndAnswers() async throws {
            let fake = try FakeSSH()
            defer { fake.tearDown() }
            let server = try connection(fake)
            await server.connect()
            let state = await server.state
            let agents = try? await server.client.call(DaemonAPI.Method.agentsList, DaemonAPI.ListRequest())
            await server.disconnect()
            #expect(state == .connected)
            #expect(agents?.arrayValue != nil)
        }

        @Test func aSecondConnectInstallsNothing() async throws {
            let fake = try FakeSSH()
            defer { fake.tearDown() }
            let server = try connection(fake)
            await server.connect()
            await server.disconnect()
            let bin = fake.home.appendingPathComponent(".agents-server/bin")
            let before = try FileManager.default.attributesOfItem(atPath: bin.appendingPathComponent("current").path)
            await server.connect()
            let after = try FileManager.default.attributesOfItem(atPath: bin.appendingPathComponent("current").path)
            let state = await server.state
            await server.disconnect()
            #expect(state == .connected, "\(state)")
            #expect(before[.modificationDate] as? Date == after[.modificationDate] as? Date)
        }

        @Test func aMacIsRefused() async throws {
            let fake = try FakeSSH()
            defer { fake.tearDown() }
            let server = try connection(fake, uname: "Darwin arm64")
            await server.connect()
            #expect(await server.state == .failed(.unsupportedSystem(system: "Darwin", architecture: "ARM64")))
            #expect(!FileManager.default.fileExists(atPath: fake.home.appendingPathComponent(".agents-server").path))
        }

        @Test func anUnknownHostFailsWithItsName() async throws {
            let fake = try FakeSSH()
            defer { fake.tearDown() }
            let server = try connection(fake, fail: "unknownHost")
            await server.connect()
            #expect(await server.state == .failed(.unknownHost))
        }

        @Test func aServerANewerAppSetUpIsNotTouched() async throws {
            let fake = try FakeSSH()
            defer { fake.tearDown() }
            let newer = try connection(fake, version: "9.0.0+1")
            await newer.connect()
            await newer.disconnect()
            let older = try connection(fake, version: "0.1.0+1")
            await older.connect()
            #expect(await older.state == .failed(.serverNewer(server: "9.0.0+1", app: "0.1.0+1")))
        }

        @Test func losingTheMasterIsOfflineAndTheServerKeepsRunning() async throws {
            let fake = try FakeSSH()
            defer { fake.tearDown() }
            let server = try connection(fake)
            await server.connect()
            let ctl = fake.hosts.appendingPathComponent("fk000001.ctl")
            let pid = try #require(Int32(String(contentsOf: ctl, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
            kill(pid, SIGKILL)
            await eventually("it says it is offline") {
                if case .offline = await server.state { return true }
                return false
            }
            let lock = fake.home.appendingPathComponent(".agents-server/root/daemon.lock")
            let daemon = try #require(Int32(String(contentsOf: lock, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
            #expect(kill(daemon, 0) == 0, "the server's daemon is still running")

            await server.connect()
            #expect(await server.state == .connected, "and it comes back")
            await server.disconnect()
        }

        @Test func twoConnectsAtOnceAreOne() async throws {
            let fake = try FakeSSH()
            defer { fake.tearDown() }
            let server = try connection(fake)
            async let first: Void = server.connect()
            async let second: Void = server.connect()
            _ = await (first, second)
            let serverState = await server.state
            #expect(serverState == .connected, "\(serverState)")
            await server.disconnect()
        }

        /// Two "builds": scripts that run this Mac's agentsd, differing only in a comment,
        /// so their checksums differ the way two builds' do.
        private func build(_ fake: FakeSSH, _ name: String) throws -> ServerBinary {
            let agentsd = try #require(ServerLinkTests.agentsd)
            let file = fake.folder.appendingPathComponent(name)
            try "#!/bin/sh\n# \(name)\nexec '\(agentsd.path)' \"$@\"\n".write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
            let sha = try #require(try? Data(contentsOf: file)).sha256Hex
            return ServerBinary(file: file, sha256: sha, version: "0.1.0+1")
        }

        private func connection(_ fake: FakeSSH, binary: ServerBinary) -> ServerConnection {
            ServerConnection(hostID: HostID(rawValue: "fk000001"), ssh: fake.command(),
                             socket: fake.hosts.appendingPathComponent("fk000001.sock"),
                             installedBy: "test") { _ in binary }
        }

        @Test func anUpdateOnAnIdleServerEndsWithTheNewDaemonAnswering() async throws {
            let fake = try FakeSSH()
            defer { fake.tearDown() }
            let old = try build(fake, "old")
            let new = try build(fake, "new")
            let first = connection(fake, binary: old)
            await first.connect()
            let firstState = await first.state
            #expect(firstState == .connected, "\(firstState)")
            let lock = fake.home.appendingPathComponent(".agents-server/root/daemon.lock")
            let oldPID = try String(contentsOf: lock, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            await first.disconnect()

            let second = connection(fake, binary: new)
            await second.connect()
            let secondState = await second.state
            #expect(secondState == .connected, "\(secondState)")
            // Answering now, not merely answered once on its way out.
            try await Task.sleep(for: .seconds(1))
            let ping = try? await second.client.call(DaemonAPI.Method.ping)
            let newPID = try String(contentsOf: lock, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            await second.disconnect()
            #expect(ping != nil)
            #expect(newPID != oldPID, "a new daemon, on the new binary")
            let current = try FileManager.default.destinationOfSymbolicLink(
                atPath: fake.home.appendingPathComponent(".agents-server/bin/current").path)
            #expect(current == ServerInstaller.binaryName(sha256: new.sha256))
        }

        @Test func removingStopsTheDaemonAndLeavesTheFoldersAlone() async throws {
            let fake = try FakeSSH()
            defer { fake.tearDown() }
            let project = fake.home.appendingPathComponent("src/api", isDirectory: true)
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            try "keep".write(to: project.appendingPathComponent("README"), atomically: true, encoding: .utf8)
            let server = try connection(fake)
            await server.connect()
            let lock = fake.home.appendingPathComponent(".agents-server/root/daemon.lock")
            let pid = try #require(Int32(String(contentsOf: lock, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
            try await server.remove(purge: false)
            await eventually("the daemon has gone") { kill(pid, 0) != 0 }
            #expect(FileManager.default.fileExists(atPath: fake.home.appendingPathComponent(".agents-server").path),
                    "without purge, what was installed stays")
            #expect(try String(contentsOf: project.appendingPathComponent("README"), encoding: .utf8) == "keep")
            #expect(await server.state == .idle)
        }

        @Test func removingWithPurgeDeletesOnlyWhatAgentsInstalled() async throws {
            let fake = try FakeSSH()
            defer { fake.tearDown() }
            let project = fake.home.appendingPathComponent("src/api", isDirectory: true)
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            try "keep".write(to: project.appendingPathComponent("README"), atomically: true, encoding: .utf8)
            let server = try connection(fake)
            await server.connect()
            try await server.remove(purge: true)
            #expect(!FileManager.default.fileExists(atPath: fake.home.appendingPathComponent(".agents-server").path))
            #expect(try String(contentsOf: project.appendingPathComponent("README"), encoding: .utf8) == "keep")
        }

        @Test func versionsCompareByNumber() {
            #expect(ServerConnection.isNewer("1.14.0+1", than: "1.9.0+99"))
            #expect(ServerConnection.isNewer("1.2.0+10", than: "1.2.0+9"))
            #expect(!ServerConnection.isNewer("1.2.0+9", than: "1.2.0+9"))
            #expect(!ServerConnection.isNewer("garbage", than: "0.1.0+1"))
        }
    }
}

import CryptoKit

private extension Data {
    var sha256Hex: String { SHA256.hash(data: self).map { String(format: "%02x", $0) }.joined() }
}
