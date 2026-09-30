import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

extension FakeSSHSuites {
    /// Putting a vendor's archive on a server (049 T029): this Mac downloads and checks it,
    /// then streams it over ssh, against the fake ssh and an ARM64 Linux home.
    @Suite("Installing an archive runtime on a server")
    struct ServerArchiveInstallerTests {
        struct Setup {
            let fake: FakeSSH
            let archive: FakeArchive
            let master: SSHMaster
            let ssh: SSHCommand

            var folder: URL { fake.home.appendingPathComponent(".agents-server/tools/antigravity") }
            var facts: ServerFacts {
                ServerFacts(system: "Linux", architecture: .aarch64, home: fake.home.path, freeBytes: 1 << 40,
                            installedVersion: nil, streamLocalForwarding: true, libc: .glibc(major: 2, minor: 36))
            }
        }

        static func setUp(tarGz: Bool = true, wrongChecksum: Bool = false) async throws -> Setup {
            let fake = try FakeSSH()
            let archive = try FakeArchive(wrongChecksum: wrongChecksum, tarGz: tarGz, platform: "linux-aarch64")
            let ssh = fake.command()
            let master = SSHMaster(command: ssh, socket: fake.hosts.appendingPathComponent("fk000001.sock"))
            try await master.start(forwardingTo: nil)
            return Setup(fake: fake, archive: archive, master: master, ssh: ssh)
        }

        static func tearDown(_ setup: Setup) async {
            await setup.master.stop()
            setup.fake.tearDown()
            setup.archive.remove()
        }

        /// A toolset already there and `current`, which an install beside it must leave be.
        static func seedCurrent(_ setup: Setup) throws {
            let old = setup.folder.appendingPathComponent("old")
            try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
            try Data().write(to: old.appendingPathComponent("ok"))
            try FileManager.default.createSymbolicLink(atPath: setup.folder.appendingPathComponent("current").path,
                                                       withDestinationPath: "old")
        }

        static func current(_ setup: Setup) throws -> String {
            try FileManager.default.destinationOfSymbolicLink(atPath: setup.folder.appendingPathComponent("current").path)
        }

        @Test(arguments: [true, false])
        func aSuccessIsWholeBesideCurrentAndItsShimRuns(tarGz: Bool) async throws {
            let setup = try await Self.setUp(tarGz: tarGz)
            defer { Task { await Self.tearDown(setup) } }
            try Self.seedCurrent(setup)
            let steps = Steps()
            try await ServerArchiveInstaller(ssh: setup.ssh).install(setup.archive.toolset, on: setup.facts) {
                steps.add($0)
            }

            let whole = setup.folder.appendingPathComponent(setup.archive.toolset.id)
            #expect(FileManager.default.fileExists(atPath: whole.appendingPathComponent("ok").path))
            #expect(FileManager.default.fileExists(atPath: whole.appendingPathComponent(Toolset.manifestFile).path))
            #expect(try Self.current(setup) == "old", "installing never moves current")
            #expect(try FileManager.default.contentsOfDirectory(atPath: setup.folder.path).sorted()
                    == ["current", "old", setup.archive.toolset.id].sorted(), "no .part- is left")
            #expect(!FileManager.default.fileExists(atPath: whole.appendingPathComponent("archive.tar.gz").path))

            let ran = try await setup.ssh.run(setup.ssh.runArguments(
                "\"$HOME/.agents-server/tools/antigravity/\(setup.archive.toolset.id)/bin/agy_acp_server\" --hello"))
            #expect(ran.stdout == "fake server --uid= --hello\n")
            #expect(steps.all.first?.hasPrefix("Downloading Antigravity (") == true)
            #expect(steps.all.contains("Checking the download"))
            #expect(steps.all.last == "Copying Antigravity to the server")
        }

        @Test func aStreamCutOffMidwayLeavesNothingAndCurrentAlone() async throws {
            let setup = try await Self.setUp()
            defer { Task { await Self.tearDown(setup) } }
            try Self.seedCurrent(setup)
            // The first half of a real bundle: what arrives when the connection drops.
            let entry = try #require(setup.archive.toolset.manifest.platforms["linux-aarch64"])
            let work = setup.archive.root.appendingPathComponent("work", isDirectory: true)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let bundle = try await ServerArchiveInstaller.bundle(setup.archive.toolset, entry: entry, in: work) { _ in }
            let data = try Data(contentsOf: bundle)
            let cut = work.appendingPathComponent("cut.tar.gz")
            try data.prefix(data.count / 2).write(to: cut)

            let out = try await setup.ssh.run(
                setup.ssh.runArguments(ServerArchiveInstaller.installScript(setup.archive.toolset)), stdin: cut)
            #expect(out.status != 0)
            #expect(try Self.current(setup) == "old")
            #expect(try FileManager.default.contentsOfDirectory(atPath: setup.folder.path).sorted() == ["current", "old"],
                    "neither the part nor a toolset without ok is left")
        }

        @Test func aDownloadThatDoesNotMatchSendsNothing() async throws {
            let setup = try await Self.setUp(wrongChecksum: true)
            defer { Task { await Self.tearDown(setup) } }
            await #expect(throws: HostProblem.toolsetChecksum) {
                try await ServerArchiveInstaller(ssh: setup.ssh).install(setup.archive.toolset, on: setup.facts)
            }
            #expect(!FileManager.default.fileExists(atPath: setup.folder.path), "the server was not touched")
        }

        @Test func aServerWithNoBuildOfItsOwnIsRefusedBeforeAnyDownload() async throws {
            let setup = try await Self.setUp()
            defer { Task { await Self.tearDown(setup) } }
            var facts = setup.facts
            facts.architecture = .x86_64
            #expect(throws: HostProblem.unsupportedSystem(system: "Linux", architecture: "x86-64")) {
                try ServerArchiveInstaller.platform(facts, setup.archive.toolset).get()
            }
            facts = setup.facts
            facts.freeBytes = 10
            #expect(throws: HostProblem.diskFullForTools(needed: 1024, free: 10)) {
                try ServerArchiveInstaller.platform(facts, setup.archive.toolset).get()
            }
        }
    }
}

extension ServerInstallerProbeFacts {
    @Test func theProbeSaysWhetherTheCPUHasAVX2AndMuslPicksMuslBuilds() throws {
        var facts = ServerFacts(system: "Linux", architecture: .x86_64, home: "/h", freeBytes: 0,
                                installedVersion: nil, streamLocalForwarding: true)
        ServerInstaller.readClaudeLines(["avx2:no", "libc:musl libc (x86_64)"], into: &facts)
        #expect(!facts.avx2)
        #expect(facts.archiveFacts == ArchiveToolset.HostFacts(base: "linux-x86_64", avx2: false, musl: true))
        ServerInstaller.readClaudeLines(["avx2:unknown"], into: &facts)
        #expect(facts.avx2, "a server that cannot say is taken to have it")
        facts.system = "Darwin"
        #expect(facts.archiveFacts == nil)
    }
}

@Suite("The server probe's archive facts")
struct ServerInstallerProbeFacts {}

private final class Steps: @unchecked Sendable {
    private let lock = NSLock()
    private var steps: [String] = []
    func add(_ step: String) { lock.lock(); steps.append(step); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return steps }
}
