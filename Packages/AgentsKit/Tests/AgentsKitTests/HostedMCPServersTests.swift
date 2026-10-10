import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// MCP servers the daemon hosts (#488): one real stdio server shared by several tokens,
/// through the app's endpoint as a runtime reaches it.
@Suite("Hosted MCP servers", .timeLimit(.minutes(1)))
struct HostedMCPServersTests {
    private let echo = MCPServer(name: "echo", transport: .stdio(command: "python3", args: [MCPClientTests.script],
                                                                  env: [:]))
    private let key = MCPClientPool.Key(scope: "/p", name: "echo", entry: "e1")
    private var temp: URL { FileManager.default.temporaryDirectory }

    private func body(_ method: String, id: Int = 1, params: JSONValue = [:]) -> Data {
        (try? JSONEncoder().encode(["jsonrpc": "2.0", "id": .int(id), "method": .string(method),
                                    "params": params] as JSONValue)) ?? Data()
    }

    private func call(_ endpoint: AppToolsEndpoint, _ path: String, token: String, session: String? = nil,
                      _ method: String, id: Int = 1, params: JSONValue = [:]) async -> (Int, JSONValue?, String?) {
        var headers = ["Authorization": "Bearer \(token)"]
        if let session { headers["Mcp-Session-Id"] = session }
        let reply = await endpoint.answer(method: "POST", path: path, headers: headers,
                                          body: body(method, id: id, params: params))
        return (reply.status, try? JSONValue.parse(reply.body), reply.headers["Mcp-Session-Id"])
    }

    private func endpoint(_ hosted: HostedMCPServers) -> AppToolsEndpoint {
        AppToolsEndpoint(relay: { _, _ in .success([:]) }, hosted: hosted, log: { _ in })
    }

    @Test func twoSessionsShareOneProcessWithTheirOwnIds() async throws {
        let hosted = HostedMCPServers(logFolder: nil, log: { _ in })
        let endpoint = endpoint(hosted)
        let path = try await hosted.use(echo, key: key, project: "/p", cwd: temp, user: "a")
        #expect(try await hosted.use(echo, key: key, project: "/p", cwd: temp, user: "b") == path)

        let (status, initialized, sessionA) = await call(endpoint, path, token: "a", "initialize",
                                                         params: ["protocolVersion": "2025-03-26"])
        #expect(status == 200)
        // The server's answer, with the version the client asked for.
        #expect(initialized?["result"]?["serverInfo"]?["name"]?.stringValue == "echo")
        #expect(initialized?["result"]?["protocolVersion"]?.stringValue == "2025-03-26")
        #expect(sessionA != nil)
        let (_, _, sessionB) = await call(endpoint, path, token: "b", "initialize")

        // Both use id 1 at once; each gets its own answer back under it.
        async let first = call(endpoint, path, token: "a", session: sessionA, "tools/call",
                               params: ["name": "echo", "arguments": ["say": "a", "sleep": 0.3]])
        async let second = call(endpoint, path, token: "b", session: sessionB, "tools/call",
                                params: ["name": "echo", "arguments": ["say": "b"]])
        let (a, b) = await (first, second)
        #expect(a.1?["id"]?.intValue == 1)
        #expect(b.1?["id"]?.intValue == 1)
        #expect(a.1?["result"]?["echo"]?["say"]?.stringValue == "a")
        #expect(b.1?["result"]?["echo"]?["say"]?.stringValue == "b")
        #expect(a.1?["result"]?["pid"] == b.1?["result"]?["pid"])
        #expect(await hosted.snapshot().servers.map(\.state) == [.running])
        await hosted.stopAll()
    }

    @Test func aTokenThatDoesNotUseTheServerIsNotServed() async throws {
        let hosted = HostedMCPServers(logFolder: nil, log: { _ in })
        let endpoint = endpoint(hosted)
        let path = try await hosted.use(echo, key: key, project: nil, cwd: temp, user: "a")
        #expect(await call(endpoint, path, token: "stranger", "initialize").0 == 404)
        #expect(await call(endpoint, HostedMCPServers.pathPrefix + "nothing", token: "a", "initialize").0 == 404)
        #expect(await call(endpoint, path, token: "a", session: "made-up", "tools/list").0 == 404)
        await hosted.release("a")
        #expect(await call(endpoint, path, token: "a", "initialize").0 == 404)
    }

    @Test func itIdlesWhenTheLastUserGoesAndStartsAgainOnTheNextCall() async throws {
        let hosted = HostedMCPServers(logFolder: nil, log: { _ in })
        let endpoint = endpoint(hosted)
        let path = try await hosted.use(echo, key: key, project: nil, cwd: temp, user: "a")
        #expect(await hosted.pid(key) == nil)
        _ = await call(endpoint, path, token: "a", "initialize")
        let first = try #require(await hosted.pid(key))
        await hosted.release("a")
        #expect(await hosted.snapshot().servers.first?.state == .idle)
        #expect(await hosted.pid(key) == nil)

        _ = try await hosted.use(echo, key: key, project: nil, cwd: temp, user: "c")
        _ = await call(endpoint, path, token: "c", "initialize")
        let second = try #require(await hosted.pid(key))
        #expect(first != second)
        await hosted.stopAll()
    }

    @Test func aServerThatStopsWhileInUseIsStartedAgainWithItsErrorKept() async throws {
        let hosted = HostedMCPServers(logFolder: nil, log: { _ in })
        let endpoint = endpoint(hosted)
        let path = try await hosted.use(echo, key: key, project: nil, cwd: temp, user: "a")
        let (_, _, session) = await call(endpoint, path, token: "a", "initialize")
        let first = try #require(await hosted.pid(key))
        let (_, died, _) = await call(endpoint, path, token: "a", session: session, "tools/call",
                                      params: ["name": "echo", "arguments": ["exit": true]])
        #expect(died?["error"]?["message"]?.stringValue?.contains("stopped") == true)
        let status = try #require(await hosted.snapshot().servers.first)
        #expect(status.state == .restarting)
        #expect(status.lastError == "It stopped (exit code 0).")

        // Started again after a second; the session it had still works.
        var restarted = await hosted.snapshot().servers.first
        for _ in 0..<40 where restarted?.state != .running {
            try await Task.sleep(for: .milliseconds(100))
            restarted = await hosted.snapshot().servers.first
        }
        #expect(restarted?.state == .running)
        #expect(restarted?.restarts == 1)
        let (status2, answer, _) = await call(endpoint, path, token: "a", session: session, "tools/list")
        #expect(status2 == 200)
        #expect(answer?["result"]?["tools"]?.arrayValue?.count == 1)
        #expect(await hosted.pid(key) != first)
        await hosted.stopAll()
    }

    @Test func aMissingCommandSaysSo() async throws {
        let hosted = HostedMCPServers(logFolder: nil, log: { _ in })
        let endpoint = endpoint(hosted)
        let missing = MCPServer(name: "nope", transport: .stdio(command: "no-such-mcp-\(UUID().uuidString)",
                                                                 args: [], env: [:]))
        let path = try await hosted.use(missing, key: key, project: nil, cwd: temp, user: "a")
        let (_, answer, _) = await call(endpoint, path, token: "a", "initialize")
        #expect(answer?["error"] != nil)
        var lastError = await hosted.snapshot().servers.first?.lastError
        for _ in 0..<20 where lastError == nil {
            try await Task.sleep(for: .milliseconds(50))
            lastError = await hosted.snapshot().servers.first?.lastError
        }
        // With what env said on stderr after it.
        #expect(lastError?.hasPrefix("The command was not found.") == true)
        await hosted.stopAll()
    }

    @Test func moreThanTheLimitAreRefused() async throws {
        let hosted = HostedMCPServers(logFolder: nil, log: { _ in })
        for index in 0..<HostedMCPServers.limit {
            _ = try await hosted.use(echo, key: .init(scope: "/p", name: "s\(index)", entry: "e"), project: nil,
                                     cwd: temp, user: "a")
        }
        await #expect(throws: HostedMCPServers.Refusal.tooMany) {
            try await hosted.use(echo, key: .init(scope: "/p", name: "one-more", entry: "e"), project: nil,
                                 cwd: temp, user: "a")
        }
        // A server already in use takes another user.
        _ = try await hosted.use(echo, key: .init(scope: "/p", name: "s0", entry: "e"), project: nil,
                                 cwd: temp, user: "b")
        await hosted.stopAll()
    }

    @Test func logNamesAreTheSameRunAfterRun() {
        let one = HostedMCPServers.logName(.init(scope: "/a", name: "ci watcher", entry: "1"))
        #expect(one == HostedMCPServers.logName(.init(scope: "/a", name: "ci watcher", entry: "2")))
        #expect(one != HostedMCPServers.logName(.init(scope: "/b", name: "ci watcher", entry: "1")))
        #expect(one.hasPrefix("ci_watcher-"))
    }

    @Test func theRowSaysWhatItIsDoing() {
        let idle = DaemonAPI.HostedMCPStatus(name: "ci", project: "/Users/a/Agents", state: .idle)
        #expect(HostedMCPWords.place(idle) == "Agents")
        #expect(HostedMCPWords.line(idle) == "Idle \u{00B7} nothing uses it")
        #expect(HostedMCPWords.lastError(idle) == nil)
        let own = DaemonAPI.HostedMCPStatus(name: "gh", project: nil, state: .running, users: 1)
        #expect(HostedMCPWords.place(own) == "Your own (~/.agents/mcp.json)")
        #expect(HostedMCPWords.line(own) == "Running \u{00B7} 1 using it")
        let down = DaemonAPI.HostedMCPStatus(name: "ci", project: "/p", state: .restarting,
                                             lastError: "It stopped (exit code 1).", restarts: 2, users: 3)
        #expect(HostedMCPWords.line(down) == "Stopped; starting again \u{00B7} restarted 2 times")
        #expect(HostedMCPWords.lastError(down) == "It stopped (exit code 1).")
        var back = down
        back.state = .running
        #expect(HostedMCPWords.lastError(back) == "Last stopped: It stopped (exit code 1).")
    }

    /// The MCP Servers row under Activity (#589), as the web's `hostedTally`.
    @Test func theActivityRowCountsRunningOrStopped() {
        #expect(HostedMCPWords.tally([]) == nil)
        let running = DaemonAPI.HostedMCPStatus(name: "gh", project: nil, state: .running, users: 1)
        let idle = DaemonAPI.HostedMCPStatus(name: "ci", project: "/p", state: .idle)
        #expect(HostedMCPWords.tally([running, idle])?.words == "1 running")
        #expect(HostedMCPWords.tally([running, idle])?.stopped == false)
        let down = DaemonAPI.HostedMCPStatus(name: "ci", project: "/p", state: .restarting, users: 1)
        #expect(HostedMCPWords.tally([running, down])?.words == "1 stopped")
        #expect(HostedMCPWords.tally([running, down])?.stopped == true)
    }

    // MARK: mcp.json

    @Test func hostedIsReadFromTheFile() throws {
        let folder = temp.appending(path: "hosted-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "mcp.json")
        try #"{"mcpServers":{"ci":{"command":"node","hosted":true},"gh":{"command":"gh"},"#
            .appending(#""off":{"command":"x","hosted":false}}}"#).write(to: file, atomically: true, encoding: .utf8)
        #expect(PersonalDotAgents.hostedNames(at: file) == ["ci"])
    }

    @Test func hostedOnlyGoesWithACommand() {
        let remote = PersonalDotAgents.parseServers(Data(#"{"mcpServers":{"r":{"url":"https://x","hosted":true}}}"#.utf8))
        guard case .failure(let problem) = remote else { Issue.record("taken"); return }
        #expect(problem.message.contains("only a local server can be hosted"))
        let odd = PersonalDotAgents.parseServers(Data(#"{"mcpServers":{"r":{"command":"x","hosted":"yes"}}}"#.utf8))
        guard case .failure = odd else { Issue.record("taken"); return }
    }
}
