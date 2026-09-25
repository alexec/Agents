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
    }
}
