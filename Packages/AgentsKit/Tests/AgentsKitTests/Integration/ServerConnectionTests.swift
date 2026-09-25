import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// A server from nothing to answering, and what happens when it goes (037).
@Suite("Connecting to a server", .serialized)
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

    @Test func versionsCompareByNumber() {
        #expect(ServerConnection.isNewer("1.14.0+1", than: "1.9.0+99"))
        #expect(ServerConnection.isNewer("1.2.0+10", than: "1.2.0+9"))
        #expect(!ServerConnection.isNewer("1.2.0+9", than: "1.2.0+9"))
        #expect(!ServerConnection.isNewer("garbage", than: "0.1.0+1"))
    }
}
