import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// How `agentsd` reads its own command line (037).
///
/// A server's daemon is started over ssh with `--serve --detach`; the Mac's is started by
/// the window with nothing. The rule is pure so it is testable without starting either.
@Suite("The daemon's command line")
struct DaemonCommandLineTests {
    @Test func noArgumentsIsTheMacsDaemon() {
        let line = DaemonCommandLine(["/x/agentsd"])
        #expect(line.mode == .daemon(serve: false, detach: false))
    }

    @Test func aServerAsksToServeAndDetach() {
        let line = DaemonCommandLine(["/x/agentsd", "--root", "/home/a/.agents-server/root", "--serve", "--detach"])
        #expect(line.mode == .daemon(serve: true, detach: true))
    }

    @Test func theDetachedChildIsToldEverythingButDetach() {
        let line = DaemonCommandLine(["/x/agentsd", "--root", "/r", "--serve", "--detach"])
        #expect(line.childArguments == ["--root", "/r", "--serve"])
    }

    @Test func mcpIsTheHelperNotTheDaemon() {
        let line = DaemonCommandLine(["/x/agentsd", "mcp", "tok", "--no-agent-tools"])
        #expect(line.mode == .mcp(token: "tok"))
    }

    @Test func aServingDaemonNeverLeavesForBeingIdle() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("serve-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let locations = StoreLocations(root: root)
        try locations.createDirectories()
        let core = DaemonCore(store: try AgentStore(locations: locations), locations: locations,
                              launcher: FakeLauncher())
        #expect(await core.shouldExit, "nothing held and nobody connected")
        await core.setExitsWhenIdle(false)
        #expect(await core.shouldExit == false, "a server keeps its schedules with no Mac")
    }

    @Test func aDetachedChildIsInASessionOfItsOwnAndOutlivesItsParent() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("detach-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = folder.appendingPathComponent("out.log")
        let pid = try Spawn.detached(executable: URL(filePath: "/bin/sh"),
                                     arguments: ["-c", "echo started; ps -o sess= -p $$; sleep 5"],
                                     environment: ["PATH": "/usr/bin:/bin"],
                                     log: log)
        defer { POSIX.kill(pid, SIGKILL) }
        #expect(pid > 0)
        #expect(getsid(pid) == pid, "a session leader, so the window quitting does not take it")
        #expect(getsid(pid) != getsid(0))
    }
}
