#if canImport(CryptoKit)
import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// A server not in the registry, typed on the sheet: Verify connects before anything is
/// written, and Add writes exactly what answered (#305).
@Suite("MCP server added by hand", .timeLimit(.minutes(1)))
struct MCPAddByHandTests {
    private let secret = "SENTINEL-305e-by-hand"

    private struct World {
        let locations: StoreLocations
        let home: URL
        let core: DaemonCore
        var mcp: URL { MCPJSONFile.personalURL(home: home) }
    }

    private func world() throws -> World {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "MCPAddByHandTests-\(UUID().uuidString)").resolvingSymlinksInPath()
        let home = base.appending(path: "home")
        for url in [base.appending(path: "root"), home.appending(path: ".agents")] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        var locations = StoreLocations(root: base.appending(path: "root"))
        locations.personalHome = home
        let core = DaemonCore(store: try AgentStore(locations: locations), locations: locations,
                              discovery: .findsEverything, launcher: FakeLauncher())
        return World(locations: locations, home: home, core: core)
    }

    private func echo(_ name: String = "echo", secret value: String = "") -> DaemonAPI.MCPHandServer {
        .init(name: name, kind: .command, command: "python3", args: [MCPClientTests.script],
              env: [.init(name: "API_KEY", value: value, secret: true), .init(name: "MODE", value: "plain")])
    }

    @Test func verifyConnectsWritesNothingAndAddWritesWhatAnswered() async throws {
        let w = try world()
        try #"{"mcpServers": {"kept": {"command": "kept-mcp"}}}"#.write(to: w.mcp, atomically: true, encoding: .utf8)
        let before = try Data(contentsOf: w.mcp)

        let answer = await w.core.mcpVerify(.init(destination: .personal, server: echo(secret: secret)))
        #expect(answer.error == nil)
        #expect(answer.outcome == .answered(serverName: "echo", version: "1", tools: ["echo"]))
        #expect(answer.entry?["env"]?["API_KEY"]?.stringValue == "${API_KEY}")
        #expect(try Data(contentsOf: w.mcp) == before, "verify writes nothing")
        #expect(!FileManager.default.fileExists(atPath: SecretsEnv.url(home: w.home).path))

        let id = try #require(answer.verifyID)
        let added = try await w.core.mcpAddByHand(.init(verifyID: id, destination: .personal))
        #expect(added.server?.byHand == true)
        #expect(added.server?.run == .command)

        let text = try String(contentsOf: w.mcp, encoding: .utf8)
        #expect(text.contains("\"kept\""))
        #expect(text.contains("${API_KEY}"))
        #expect(!text.contains(secret))
        #expect(SecretsEnv.load(from: SecretsEnv.url(home: w.home)).value(of: "API_KEY") == secret)

        // Listed as the app's, so it has Remove; and Remove takes it out.
        let listed = try await w.core.mcpList(.init(destination: .personal))
        let row = try #require(listed.servers.first { $0.name == "echo" })
        #expect(row.managed?.byHand == true)
        #expect(listed.servers.first { $0.name == "kept" }?.managed == nil)
        _ = try await w.core.mcpRemove(.init(destination: .personal, name: "echo"))
        #expect(try MCPJSONFile.entry(named: "echo", at: w.mcp) == nil)

        // A verify is added once.
        await #expect(throws: JSONRPCError.self) {
            try await w.core.mcpAddByHand(.init(verifyID: id, destination: .personal))
        }
    }

    @Test func aServerThatDoesNotAnswerStaysOnTheSheetAndNothingIsWritten() async throws {
        let w = try world()
        var broken = echo(secret: secret)
        broken.command = "no-such-mcp-\(UUID().uuidString)"
        let answer = await w.core.mcpVerify(.init(destination: .personal, server: broken))
        #expect(answer.verifyID == nil)
        #expect(answer.outcome == .failed("The command was not found."))
        #expect(!FileManager.default.fileExists(atPath: w.mcp.path))
        #expect(!FileManager.default.fileExists(atPath: SecretsEnv.url(home: w.home).path))
    }

    @Test func aNameAlreadyThereAndAMissingSecretAreRefusedBeforeConnecting() async throws {
        let w = try world()
        try #"{"mcpServers": {"echo": {"command": "mine"}}}"#.write(to: w.mcp, atomically: true, encoding: .utf8)
        let taken = await w.core.mcpVerify(.init(destination: .personal, server: echo(secret: secret)))
        #expect(taken.error == .nameTaken(name: "echo"))
        #expect(taken.outcome == nil)

        let unset = await w.core.mcpVerify(.init(destination: .personal, server: echo("other")))
        #expect(unset.error == .missingSecret(name: "API_KEY"))

        var badURL = DaemonAPI.MCPHandServer(name: "web", kind: .url, url: "ftp://x")
        #expect(await w.core.mcpVerify(.init(destination: .personal, server: badURL)).error != nil)
        badURL.url = "https://ok.example/mcp"
        badURL.name = "has space"
        #expect(await w.core.mcpVerify(.init(destination: .personal, server: badURL)).error != nil)
    }

    @Test func aSecretAlreadySetIsUsedWhenLeftEmpty() async throws {
        let w = try world()
        try "API_KEY=\(secret)\n".write(to: SecretsEnv.url(home: w.home), atomically: true, encoding: .utf8)
        let answer = await w.core.mcpVerify(.init(destination: .personal, server: echo()))
        #expect(answer.verifyID != nil)
    }

    @Test func aServerThatAsksForSignInSaysSoAndCannotBeAdded() async throws {
        let w = try world()
        await w.core.setMCPVerify(timeout: .seconds(5), http: StandIn(
            unauthorized: #"Bearer resource_metadata="https://mcp.example/.well-known/oauth-protected-resource""#).send)
        let server = DaemonAPI.MCPHandServer(name: "locked", kind: .url, url: "https://mcp.example/mcp",
                                             headers: [.init(name: "X-Team", value: "t1")])
        let answer = await w.core.mcpVerify(.init(destination: .personal, server: server))
        #expect(answer.outcome == .authRequired(resourceMetadata: "https://mcp.example/.well-known/oauth-protected-resource"))
        #expect(answer.verifyID == nil)
        #expect(answer.entry?["headers"]?["X-Team"]?.stringValue == "t1")
    }

    @Test func aRemoteServerWithASecretHeaderIsAddedWithItsName() async throws {
        let w = try world()
        let standIn = StandIn()
        await w.core.setMCPVerify(timeout: .seconds(5), http: standIn.send)
        let server = DaemonAPI.MCPHandServer(name: "team-api", kind: .url, url: "https://mcp.example/mcp",
                                             headers: [.init(name: "Authorization", value: "Bearer \(secret)", secret: true)])
        let answer = await w.core.mcpVerify(.init(destination: .personal, server: server))
        #expect(answer.outcome == .answered(serverName: "stand-in", version: "2", tools: ["a", "b"]))
        #expect(standIn.requests.first?.headers["Authorization"] == "Bearer \(secret)", "verify sent the real value")
        _ = try await w.core.mcpAddByHand(.init(verifyID: try #require(answer.verifyID), destination: .personal))
        let text = try String(contentsOf: w.mcp, encoding: .utf8)
        #expect(text.contains("${TEAM_API_AUTHORIZATION}"))
        #expect(SecretsEnv.load(from: SecretsEnv.url(home: w.home)).value(of: "TEAM_API_AUTHORIZATION") == "Bearer \(secret)")
    }

    // FR-023, T046: through the daemon too.
    @Test func nothingTypedReachesTheDaemonLog() async throws {
        let w = try world()
        let log = w.locations.root.appending(path: "secret-test.log")
        DaemonLog.shared.setDestination(log)
        defer { DaemonLog.shared.setDestination(nil) }
        var server = echo(secret: secret)
        server.args.append("--flag=\(secret)")
        let answer = await w.core.mcpVerify(.init(destination: .personal, server: server))
        _ = try await w.core.mcpAddByHand(.init(verifyID: try #require(answer.verifyID), destination: .personal))
        var failing = server
        failing.name = "other"
        failing.command = "missing-\(secret)"
        _ = await w.core.mcpVerify(.init(destination: .personal, server: failing))
        DaemonLog.shared.setDestination(nil)
        let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        // The log is one for the whole process, and another suite may point it elsewhere:
        // what lands here is checked, whatever else lands.
        #expect(!text.contains(secret))
    }
}
#endif
