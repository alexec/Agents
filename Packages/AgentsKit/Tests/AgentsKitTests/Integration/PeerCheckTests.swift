import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// Who may talk to the daemon, as the kernel says rather than as the caller does.
///
/// The socket is the whole of the daemon, so the two things held here are that it is
/// this account's alone, and that an agent's token only speaks from inside the runtime
/// that agent is running in — not from anything that read it off `ps`.
@Suite("Who may talk to the daemon", .timeLimit(.minutes(1)))
struct PeerCheckTests {
    private func temporaryRoot() throws -> URL {
        let root = URL(fileURLWithPath: "/tmp/agt-peer-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
        return root
    }

    private func mode(_ path: String) throws -> Int {
        try #require(FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int)
    }

    @Test func theSocketAndItsFolderAreThisAccountsAlone() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let server = DaemonServer(url: root.appendingPathComponent("daemon.sock")) { _, _, _ in .success([:]) }
        try server.start()
        defer { server.stop() }

        #expect(try mode(root.path) == 0o700)
        #expect(try mode(root.appendingPathComponent("daemon.sock").path) == 0o600)
    }

    @Test func theKernelNamesWhoIsOnTheOtherEnd() {
        var pair: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        defer { close(pair[0]); close(pair[1]) }

        #expect(PeerCredentials.uid(of: pair[0]) == geteuid())
        #expect(PeerCredentials.pid(of: pair[0]) == getpid())
    }

    @Test func aProcessDescendsFromItsParentAndNotTheOtherWayRound() {
        #expect(PeerCredentials.descends(getpid(), from: getpid()))
        #expect(PeerCredentials.descends(getpid(), from: getppid()))
        #expect(!PeerCredentials.descends(getppid(), from: getpid()))
        #expect(!PeerCredentials.descends(-1, from: getpid()))
    }

    // MARK: Tokens

    private func coreWithAnAgent() async throws -> (DaemonCore, UUID, String, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsPeer-\(UUID().uuidString)", isDirectory: true)
        let work = root.appendingPathComponent("api", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let locations = StoreLocations(root: root)
        let core = DaemonCore(store: try AgentStore(locations: locations), locations: locations,
                              discovery: .findsEverything, launcher: FakeLauncher())
        await core.loadFromDisk()
        let id = try await core.start(DaemonAPI.StartRequest(runtimeID: "claude", cwd: Project.standardize(work),
                                                             prompt: "Lead"))
        let token = UUID().uuidString
        await core.bindAppToken(token, to: id)
        return (core, id, token, root)
    }

    /// The token read off `ps` and used from a shell: refused as if it meant nothing.
    @Test func aTokenFromOutsideItsRuntimeIsRefused() async throws {
        let (core, _, token, root) = try await coreWithAnAgent()
        defer { try? FileManager.default.removeItem(at: root) }

        for stranger: Int32 in [getpid(), -1] {
            let refusal = await core.tokenRefusal(["token": .string(token)], peer: stranger)
            #expect(refusal?.code == DaemonAPI.Failure.noSuchAgent)
            #expect(refusal?.message == "That conversation is not open to this process, so nothing was done.")
        }
    }

    @Test func aCallerInsideTheDaemonAndATokenNobodyHoldsAreLeftToTheMethod() async throws {
        let (core, _, token, root) = try await coreWithAnAgent()
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(await core.tokenRefusal(["token": .string(token)], peer: nil) == nil)
        #expect(await core.tokenRefusal(["token": .string(UUID().uuidString)], peer: getpid()) == nil)
        #expect(await core.tokenRefusal(["prompt": .string("hi")], peer: getpid()) == nil)
    }
}
