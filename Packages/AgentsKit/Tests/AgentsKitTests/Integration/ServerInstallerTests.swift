import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// Putting agentsd on a server, and taking it off again (037, contracts/ssh.md §§ 5, 6, 8).
///
/// Against the fake ssh, whose "server" is a folder on this Mac. The binary is any file:
/// what is being tested is that it arrives whole, where it should, with nothing left
/// behind when it does not.
@Suite("Installing on a server", .serialized)
struct ServerInstallerTests {
    private struct Setup {
        let fake: FakeSSH
        let master: SSHMaster
        let installer: ServerInstaller
        let binary: URL
        let sha: String

        var server: URL { fake.home.appendingPathComponent(".agents-server") }
    }

    private func setUp(uname: String? = nil, fail: String? = nil) async throws -> Setup {
        let fake = try FakeSSH()
        let ssh = fake.command(uname: uname)
        let master = SSHMaster(command: ssh, socket: fake.hosts.appendingPathComponent("fk000001.sock"))
        try await master.start(forwardingTo: nil)
        let binary = fake.folder.appendingPathComponent("agentsd-linux-aarch64")
        try Data((0..<1_000_000).map { UInt8($0 % 251) }).write(to: binary)
        let sha = try await ServerInstaller.sha256(of: binary)
        return Setup(fake: fake, master: master, installer: ServerInstaller(ssh: fail.map { fake.command(fail: $0) } ?? ssh),
                     binary: binary, sha: sha)
    }

    private func tearDown(_ setup: Setup) async {
        await setup.master.stop()
        setup.fake.tearDown()
    }

    @Test func theProbeReadsAllFiveLines() async throws {
        let setup = try await setUp()
        let facts = try await setup.installer.probe()
        await tearDown(setup)
        #expect(facts.system == "Linux")
        #expect(facts.architecture == .aarch64)
        #expect(facts.home == setup.fake.home.path)
        #expect(facts.freeBytes > 0)
        #expect(facts.installedVersion == nil)
        #expect(facts.installedSHA256 == nil)
        #expect(facts.streamLocalForwarding)
        #expect(facts.isSupported)
    }

    @Test func aMacIsRefusedBeforeAnythingIsWritten() async throws {
        let setup = try await setUp(uname: "Darwin arm64")
        let facts = try await setup.installer.probe()
        defer { Task { await tearDown(setup) } }
        #expect(!facts.isSupported)
        #expect(!FileManager.default.fileExists(atPath: setup.server.path))
    }

    @Test func installingPutsTheBinaryWhereItBelongsAndPrivately() async throws {
        let setup = try await setUp()
        try await setup.installer.install(binary: setup.binary, sha256: setup.sha, firstInstall: true)
        try await setup.installer.swapCurrent(to: setup.sha, version: "0.1.0+1", installedBy: "test")
        let facts = try await setup.installer.probe()
        await tearDown(setup)
        let name = ServerInstaller.binaryName(sha256: setup.sha)
        #expect(facts.installedSHA256 == setup.sha)
        #expect(facts.installedVersion == "0.1.0+1")
        #expect(name.hasPrefix("agentsd-"))
    }

    @Test func theInstalledFilesAreTheSameBytesWithTheRightModes() async throws {
        let setup = try await setUp()
        try await setup.installer.install(binary: setup.binary, sha256: setup.sha, firstInstall: true)
        try await setup.installer.swapCurrent(to: setup.sha, version: "0.1.0+1", installedBy: "test")
        let name = ServerInstaller.binaryName(sha256: setup.sha)
        let installed = setup.server.appendingPathComponent("bin/\(name)")
        let current = setup.server.appendingPathComponent("bin/current")
        let attributes = try FileManager.default.attributesOfItem(atPath: installed.path)
        let serverAttributes = try FileManager.default.attributesOfItem(atPath: setup.server.path)
        let rootAttributes = try FileManager.default.attributesOfItem(atPath: setup.server.appendingPathComponent("root").path)
        let same = try Data(contentsOf: installed) == Data(contentsOf: setup.binary)
        let target = try FileManager.default.destinationOfSymbolicLink(atPath: current.path)
        await tearDown(setup)
        #expect(same)
        #expect((attributes[.posixPermissions] as? Int) == 0o700)
        #expect((serverAttributes[.posixPermissions] as? Int) == 0o700)
        #expect((rootAttributes[.posixPermissions] as? Int) == 0o700)
        #expect(target == name)
    }

    @Test func aBadChecksumOnAFirstInstallLeavesNothing() async throws {
        let setup = try await setUp()
        await #expect(throws: HostProblem.self) {
            try await setup.installer.install(binary: setup.binary, sha256: String(repeating: "0", count: 64),
                                              firstInstall: true)
        }
        let left = FileManager.default.fileExists(atPath: setup.server.path)
        await tearDown(setup)
        #expect(!left)
    }

    @Test func aBadChecksumOnAnUpdateLeavesTheOldOneRunning() async throws {
        let setup = try await setUp()
        try await setup.installer.install(binary: setup.binary, sha256: setup.sha, firstInstall: true)
        try await setup.installer.swapCurrent(to: setup.sha, version: "0.1.0+1", installedBy: "test")
        await #expect(throws: HostProblem.self) {
            try await setup.installer.install(binary: setup.binary, sha256: String(repeating: "0", count: 64),
                                              firstInstall: false)
        }
        let bin = setup.server.appendingPathComponent("bin")
        let names = try FileManager.default.contentsOfDirectory(atPath: bin.path)
        let target = try FileManager.default.destinationOfSymbolicLink(atPath: bin.appendingPathComponent("current").path)
        await tearDown(setup)
        #expect(target == ServerInstaller.binaryName(sha256: setup.sha))
        #expect(!names.contains { $0.hasSuffix(".part") })
    }

    @Test func tooLittleRoomIsSaidBeforeAnyWrite() async throws {
        let setup = try await setUp()
        var facts = try await setup.installer.probe()
        facts.freeBytes = 10_000_000
        #expect(throws: HostProblem.diskFull(freeBytes: 10_000_000)) {
            try ServerInstaller.checkRoom(facts)
        }
        let left = FileManager.default.fileExists(atPath: setup.server.path)
        await tearDown(setup)
        #expect(!left)
    }

    @Test func purgingRemovesOnlyWhatWasInstalled() async throws {
        let setup = try await setUp()
        let project = setup.fake.home.appendingPathComponent("src/api", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try "keep me".write(to: project.appendingPathComponent("README"), atomically: true, encoding: .utf8)
        try await setup.installer.install(binary: setup.binary, sha256: setup.sha, firstInstall: true)
        try await setup.installer.swapCurrent(to: setup.sha, version: "0.1.0+1", installedBy: "test")
        try await setup.installer.purge()
        let gone = !FileManager.default.fileExists(atPath: setup.server.path)
        let kept = try String(contentsOf: project.appendingPathComponent("README"), encoding: .utf8)
        await tearDown(setup)
        #expect(gone)
        #expect(kept == "keep me")
    }

    @Test func anOldBinaryIsDeletedOnlyWhenAskedAfterTheNextConnect() async throws {
        let setup = try await setUp()
        try await setup.installer.install(binary: setup.binary, sha256: setup.sha, firstInstall: true)
        try await setup.installer.swapCurrent(to: setup.sha, version: "0.1.0+1", installedBy: "test")
        let newer = setup.fake.folder.appendingPathComponent("agentsd-new")
        try Data((0..<500_000).map { UInt8($0 % 13) }).write(to: newer)
        let newerSHA = try await ServerInstaller.sha256(of: newer)
        try await setup.installer.install(binary: newer, sha256: newerSHA, firstInstall: false)
        try await setup.installer.swapCurrent(to: newerSHA, version: "0.1.0+2", installedBy: "test")
        let bin = setup.server.appendingPathComponent("bin")
        let before = try FileManager.default.contentsOfDirectory(atPath: bin.path).filter { $0.hasPrefix("agentsd-") }
        try await setup.installer.removeBinaries(except: newerSHA)
        let after = try FileManager.default.contentsOfDirectory(atPath: bin.path).filter { $0.hasPrefix("agentsd-") }
        await tearDown(setup)
        #expect(before.count == 2)
        #expect(after == [ServerInstaller.binaryName(sha256: newerSHA)])
    }
}
