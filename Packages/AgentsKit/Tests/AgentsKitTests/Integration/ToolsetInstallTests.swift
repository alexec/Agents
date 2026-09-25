import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

extension FakeSSHSuites {
    /// Putting Claude's toolset on a server (043, contracts/ssh.md §§ 1–4), against the fake
    /// ssh with a toolset small enough to install in a test.
    @Suite("Installing Claude on a server")
    struct ToolsetInstallTests {
        struct Setup {
            let fake: FakeSSH
            let tools: FakeToolset
            let master: SSHMaster
            let ssh: SSHCommand

            var claude: URL { fake.home.appendingPathComponent(".agents-server/tools/claude") }
        }

        static func setUp(npmFail: String? = nil, curlFail: String? = nil, ldd: String? = nil,
                          corruptTarball: Bool = false) async throws -> Setup {
            let fake = try FakeSSH()
            let tools = try FakeToolset(in: fake.folder, corruptTarball: corruptTarball)
            let ssh = fake.command(extra: tools.environment(npmFail: npmFail, curlFail: curlFail, ldd: ldd))
            let master = SSHMaster(command: ssh, socket: fake.hosts.appendingPathComponent("fk000001.sock"))
            try await master.start(forwardingTo: nil)
            return Setup(fake: fake, tools: tools, master: master, ssh: ssh)
        }

        static func tearDown(_ setup: Setup) async {
            await setup.master.stop()
            setup.fake.tearDown()
        }

        @Test func theProbeSeesABareServer() async throws {
            let setup = try await Self.setUp()
            defer { Task { await Self.tearDown(setup) } }
            let facts = try await ServerInstaller(ssh: setup.ssh).probe()
            #expect(facts.libc == .glibc(major: 2, minor: 36))
            #expect(facts.downloader == "curl")
            #expect(facts.toolsetID == nil)
            #expect(!facts.hasNpx)
            #expect(!facts.hasOwnClaudeSignIn)
        }
    
        /// Everything under the fake home, for proving an install touched nothing else.
        static func listing(_ home: URL, excluding prefix: String = ".agents-server") -> [String] {
            let e = FileManager.default.enumerator(atPath: home.path)
            var all: [String] = []
            while let path = e?.nextObject() as? String { if !path.hasPrefix(prefix) { all.append(path) } }
            return all.sorted()
        }

        @Test func aBareServerGetsAWholeToolsetAndNothingElseChanges() async throws {
            let setup = try await Self.setUp()
            defer { Task { await Self.tearDown(setup) } }
            try Data("export PATH=/mine\n".utf8).write(to: setup.fake.home.appendingPathComponent(".profile"))
            let before = Self.listing(setup.fake.home)
            let facts = try await ServerInstaller(ssh: setup.ssh).probe()
            let installer = ToolsetInstaller(ssh: setup.ssh)
            try await installer.install(setup.tools.toolset, on: facts)
            try await installer.swap(to: setup.tools.toolset.id)

            let id = setup.tools.toolset.id
            let whole = setup.claude.appendingPathComponent(id)
            #expect(FileManager.default.fileExists(atPath: whole.appendingPathComponent("ok").path))
            #expect(FileManager.default.fileExists(atPath: whole.appendingPathComponent(
                "lib/node_modules/@agentclientprotocol/claude-agent-acp/dist/index.js").path))
            #expect(FileManager.default.fileExists(atPath: whole.appendingPathComponent("manifest.json").path))
            #expect(FileManager.default.fileExists(atPath: whole.appendingPathComponent("node/bin/node").path))
            #expect(try FileManager.default.destinationOfSymbolicLink(
                atPath: setup.claude.appendingPathComponent("current").path) == id)
            #expect(Self.listing(setup.fake.home) == before)
            #expect(try String(contentsOf: setup.fake.home.appendingPathComponent(".profile"), encoding: .utf8)
                    == "export PATH=/mine\n")
            let mode = try FileManager.default.attributesOfItem(atPath: setup.claude.path)[.posixPermissions] as? Int
            #expect(mode == 0o700)

            let again = try await ServerInstaller(ssh: setup.ssh).probe()
            #expect(again.toolsetID == id)

            // The shim the server's daemon starts in place of npx runs the toolset's own node.
            let shim = setup.claude.appendingPathComponent("current/bin/npx")
            #expect(FileManager.default.isExecutableFile(atPath: shim.path))
            let ran = try await setup.ssh.run(setup.ssh.runArguments("\"$HOME/.agents-server/tools/claude/current/bin/npx\" -y whatever"))
            #expect(ran.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == FakeToolset.nodeVersion)
        }

        static func expectNothingLeft(_ setup: Setup) {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: setup.claude.path)) ?? []
            #expect(names.isEmpty, "left behind: \(names)")
        }

        @Test func aTarballThatDoesNotMatchLeavesNothing() async throws {
            let setup = try await Self.setUp(corruptTarball: true)
            defer { Task { await Self.tearDown(setup) } }
            let facts = try await ServerInstaller(ssh: setup.ssh).probe()
            await #expect(throws: HostProblem.toolsetChecksum) {
                try await ToolsetInstaller(ssh: setup.ssh).install(setup.tools.toolset, on: facts)
            }
            Self.expectNothingLeft(setup)
        }

        @Test func aPackageThatDoesNotMatchItsLockLeavesNothing() async throws {
            let setup = try await Self.setUp(npmFail: "integrity")
            defer { Task { await Self.tearDown(setup) } }
            let facts = try await ServerInstaller(ssh: setup.ssh).probe()
            await #expect(throws: HostProblem.toolsetChecksum) {
                try await ToolsetInstaller(ssh: setup.ssh).install(setup.tools.toolset, on: facts)
            }
            Self.expectNothingLeft(setup)
        }

        @Test func noInternetIsSaidAsSuch() async throws {
            let setup = try await Self.setUp(curlFail: "resolve")
            defer { Task { await Self.tearDown(setup) } }
            let facts = try await ServerInstaller(ssh: setup.ssh).probe()
            do {
                try await ToolsetInstaller(ssh: setup.ssh).install(setup.tools.toolset, on: facts)
                Issue.record("installed with no internet")
            } catch let problem as HostProblem {
                guard case .noInternet = problem else { Issue.record("\(problem)"); return }
            }
            Self.expectNothingLeft(setup)
        }

        @Test func npmFailingOtherwiseSaysItsLastLine() async throws {
            let setup = try await Self.setUp(npmFail: "network")
            defer { Task { await Self.tearDown(setup) } }
            let facts = try await ServerInstaller(ssh: setup.ssh).probe()
            do {
                try await ToolsetInstaller(ssh: setup.ssh).install(setup.tools.toolset, on: facts)
                Issue.record("installed with npm failing")
            } catch let problem as HostProblem {
                #expect(problem == .noInternet("npm ERR! network request failed"))
            }
            Self.expectNothingLeft(setup)
        }

        @Test func muslAndAFullDiskAreRefusedBeforeAnythingIsDownloaded() async throws {
            let setup = try await Self.setUp(ldd: "musl libc (aarch64)")
            defer { Task { await Self.tearDown(setup) } }
            let facts = try await ServerInstaller(ssh: setup.ssh).probe()
            await #expect(throws: HostProblem.unsupportedLibc("musl (Alpine)")) {
                try await ToolsetInstaller(ssh: setup.ssh).install(setup.tools.toolset, on: facts)
            }
            #expect(!FileManager.default.fileExists(atPath: setup.claude.path))
            var full = facts
            full.libc = .glibc(major: 2, minor: 36)
            full.freeBytes = 10
            #expect(ToolsetInstaller.refusal(full, setup.tools.toolset)
                    == .diskFullForTools(needed: setup.tools.toolset.manifest.minFreeBytes, free: 10))
            full.freeBytes = 1 << 40
            full.downloader = nil
            #expect(ToolsetInstaller.refusal(full, setup.tools.toolset) == .noDownloader)
        }

        @Test func tidyingKeepsOnlyTheOneInUse() async throws {
            let setup = try await Self.setUp()
            defer { Task { await Self.tearDown(setup) } }
            let facts = try await ServerInstaller(ssh: setup.ssh).probe()
            let installer = ToolsetInstaller(ssh: setup.ssh)
            try await installer.install(setup.tools.toolset, on: facts)
            try await installer.swap(to: setup.tools.toolset.id)
            let old = setup.claude.appendingPathComponent("0123456789abcdef")
            try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: setup.claude.appendingPathComponent(".part-dead"),
                                                    withIntermediateDirectories: true)
            try await installer.removeOthers(except: setup.tools.toolset.id)
            let names = try FileManager.default.contentsOfDirectory(atPath: setup.claude.path).sorted()
            #expect(names == ["current", setup.tools.toolset.id].sorted())
        }
    
        // MARK: On connect (T028)

        static func connection(_ setup: Setup, wantsClaude: Bool) throws -> ServerConnection {
            let agentsd = try #require(ServerLinkTests.agentsd)
            let toolset = setup.tools.toolset
            return ServerConnection(hostID: HostID(rawValue: "fk000002"), ssh: setup.ssh,
                                    socket: setup.fake.hosts.appendingPathComponent("fk000002.sock"),
                                    installedBy: "test",
                                    binary: { _ in
                                        ServerBinary(file: agentsd,
                                                     sha256: (try? await ServerInstaller.sha256(of: agentsd)) ?? "",
                                                     version: "0.1.0+1")
                                    },
                                    toolset: { toolset }, wantsClaude: { wantsClaude })
        }

        @Test func withACredentialInSettingsClaudeIsInstalledAsTheServerConnects() async throws {
            let setup = try await Self.setUp()
            defer { Task { await Self.tearDown(setup) } }
            let server = try Self.connection(setup, wantsClaude: true)
            await server.connect()
            let state = await server.state, claude = await server.claude
            await server.disconnect()
            #expect(state == .connected)
            #expect(claude == .ready(setup.tools.toolset.id))
        }

        @Test func withoutOneItWaitsUntilClaudeIsChosen() async throws {
            let setup = try await Self.setUp()
            defer { Task { await Self.tearDown(setup) } }
            let server = try Self.connection(setup, wantsClaude: false)
            await server.connect()
            #expect(await server.claude == .notInstalled)
            #expect(!FileManager.default.fileExists(atPath: setup.claude.appendingPathComponent("current").path))
            await server.installClaude()
            #expect(await server.claude == .ready(setup.tools.toolset.id))
            await server.disconnect()
        }

        @Test func aFailedInstallLeavesTheServerUsable() async throws {
            let setup = try await Self.setUp(curlFail: "resolve")
            defer { Task { await Self.tearDown(setup) } }
            let server = try Self.connection(setup, wantsClaude: true)
            await server.connect()
            let state = await server.state, claude = await server.claude
            let agents = try? await server.client.call(DaemonAPI.Method.agentsList, DaemonAPI.ListRequest())
            await server.disconnect()
            #expect(state == .connected)
            guard case .failed(.noInternet) = claude else { Issue.record("\(claude)"); return }
            #expect(agents?.arrayValue != nil)
        }

        @Test func aSecondConnectInstallsNothing() async throws {
            let setup = try await Self.setUp()
            defer { Task { await Self.tearDown(setup) } }
            let server = try Self.connection(setup, wantsClaude: true)
            await server.connect()
            await server.disconnect()
            let ok = setup.claude.appendingPathComponent("\(setup.tools.toolset.id)/ok")
            let before = try FileManager.default.attributesOfItem(atPath: ok.path)[.modificationDate] as? Date
            await server.connect()
            let after = try FileManager.default.attributesOfItem(atPath: ok.path)[.modificationDate] as? Date
            #expect(await server.claude == .ready(setup.tools.toolset.id))
            await server.disconnect()
            #expect(before == after)
        }
    }
}
