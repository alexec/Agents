import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

extension FakeSSHSuites {
    /// A server's daemon, reached the way the window will reach it (037): installed over the
    /// fake ssh, started over it, and spoken to through the forwarded socket. This Mac's
    /// `agentsd` stands in for the Linux one.
    @Suite("Reaching a server's daemon")
    struct ServerLinkTests {
        /// The Mac `agentsd` from `Daemon/`, built once if it is not there.
        static let agentsd: URL? = {
            let daemon = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("Daemon", isDirectory: true)
            let built = daemon.appendingPathComponent(".build/out/Products/Debug/agentsd")
            if !FileManager.default.isExecutableFile(atPath: built.path) {
                let swift = Process()
                swift.executableURL = URL(filePath: "/usr/bin/xcrun")
                swift.arguments = ["swift", "build", "--package-path", daemon.path, "--product", "agentsd"]
                // Ended on terminationHandler: waitUntilExit hangs off the main thread.
                let done = DispatchSemaphore(value: 0)
                swift.terminationHandler = { _ in done.signal() }
                if (try? swift.run()) != nil { done.wait() }
            }
            return FileManager.default.isExecutableFile(atPath: built.path) ? built : nil
        }()

        @Test func connectingStartsTheDaemonOverSSHAndItAnswersThroughTheForward() async throws {
            let agentsd = try #require(Self.agentsd, "Daemon/ could not be built")
            let fake = try FakeSSH()
            defer { fake.tearDown() }
            let ssh = fake.command()
            let socket = fake.hosts.appendingPathComponent("fk000001.sock")
            let master = SSHMaster(command: ssh, socket: socket)
            try await master.start(forwardingTo: nil)
            let installer = ServerInstaller(ssh: ssh)
            let facts = try await installer.probe()
            let sha = try await ServerInstaller.sha256(of: agentsd)
            try await installer.install(binary: agentsd, sha256: sha, firstInstall: true)
            try await installer.swapCurrent(to: sha, version: "test", installedBy: "test")
            await master.stop()
            try await master.start(forwardingTo: facts.home + "/.agents-server/root/daemon.sock")

            let link = ServerLink(socket: socket, installer: installer) { await master.isRunning }
            let client = DaemonClient(link: link)
            try await client.connect(timeout: .seconds(20))
            let agents = try await client.call(DaemonAPI.Method.agentsList, DaemonAPI.ListRequest())
            await client.disconnect()
            await master.stop()
            #expect(agents.arrayValue != nil)
            #expect(FileManager.default.fileExists(
                atPath: fake.home.appendingPathComponent(".agents-server/root/daemon.lock").path))
        }

        @Test func withTheMasterDownItIsOfflineAtOnceAndStartsNothing() async throws {
            let fake = try FakeSSH()
            defer { fake.tearDown() }
            let link = ServerLink(socket: fake.hosts.appendingPathComponent("fk000001.sock"),
                                  installer: ServerInstaller(ssh: fake.command())) { false }
            let client = DaemonClient(link: link)
            let started = ContinuousClock.now
            await #expect(throws: (any Error).self) { try await client.connect(timeout: .seconds(1)) }
            #expect(ContinuousClock.now - started < .seconds(3))
            #expect(!FileManager.default.fileExists(atPath: fake.home.appendingPathComponent(".agents-server").path))
        }
    }
}
