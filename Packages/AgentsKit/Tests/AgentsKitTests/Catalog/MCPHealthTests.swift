#if canImport(CryptoKit)
import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// Every server in the host's `mcp.json` files and how each is doing (#753): one not
/// hosted is checked as a session would reach it; hosted, waiting, missing a secret and sse
/// are never started.
@Suite("MCP server health", .timeLimit(.minutes(1)))
struct MCPHealthTests {
    private struct World {
        let home: URL
        let project: URL
        let core: DaemonCore
        var mcp: URL { MCPJSONFile.personalURL(home: home) }
    }

    private func world() async throws -> World {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "MCPHealthTests-\(UUID().uuidString)").resolvingSymlinksInPath()
        let home = base.appending(path: "home")
        let project = base.appending(path: "project")
        for url in [base.appending(path: "root"), home.appending(path: ".agents"), project.appending(path: ".agents")] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        var locations = StoreLocations(root: base.appending(path: "root"))
        locations.personalHome = home
        let core = DaemonCore(store: try AgentStore(locations: locations), locations: locations,
                              discovery: .findsEverything, launcher: FakeLauncher())
        await core.setMCPHealth(timeout: .seconds(10))
        return World(home: home, project: project, core: core)
    }

    private var echo: String { #"{"command": "python3", "args": ["\#(MCPClientTests.script)"]}"# }

    /// The snapshot once `done` holds of it.
    private func snapshot(_ core: DaemonCore, until done: (DaemonAPI.MCPHealthSnapshot) -> Bool)
        async throws -> DaemonAPI.MCPHealthSnapshot {
        for _ in 0..<200 {
            let snapshot = await core.mcpHealthSnapshot()
            if done(snapshot) { return snapshot }
            try await Task.sleep(for: .milliseconds(50))
        }
        Issue.record("the snapshot never got there")
        return await core.mcpHealthSnapshot()
    }

    @Test func everyPersonalServerIsListedAndOnlyTheCheckableOnesAreChecked() async throws {
        let w = try await world()
        try """
        {"mcpServers": {
          "echo": \(echo),
          "broken": {"command": "no-such-mcp-\(UUID().uuidString)"},
          "shared": {"command": "python3", "args": ["\(MCPClientTests.script)"], "hosted": true},
          "keyed": {"command": "python3", "args": ["\(MCPClientTests.script)"], "env": {"KEY": "${NOT_SET_753}"}},
          "old": {"type": "sse", "url": "https://old.example/sse"}
        }}
        """.write(to: w.mcp, atomically: true, encoding: .utf8)

        await w.core.startMCPHealth()
        let done = try await snapshot(w.core) { snapshot in
            let checked = snapshot.personal.filter { $0.name == "echo" || $0.name == "broken" }
            return checked.count == 2 && checked.allSatisfy { $0.check == .answered || $0.check == .failed }
        }
        await w.core.stopMCPHealth()

        let byName = Dictionary(uniqueKeysWithValues: done.personal.map { ($0.name, $0) })
        #expect(done.personal.map(\.name) == ["echo", "broken", "shared", "keyed", "old"], "the file's order")
        #expect(byName["echo"]?.check == .answered)
        #expect(byName["echo"]?.tools == 1)
        #expect(byName["echo"]?.checkedAt != nil)
        #expect(byName["broken"]?.check == .failed)
        #expect(byName["broken"]?.lastError == "The command was not found.")
        #expect(byName["shared"]?.hosted == true)
        #expect(byName["shared"]?.check == .unchecked, "a hosted server is never checked")
        #expect(byName["keyed"]?.check == .missingSecret)
        #expect(byName["old"]?.check == .oldTransport)
        #expect(byName["old"]?.transport == .sse)
        #expect(MCPHealthWords.tally(done.personal)?.words == "1 not answering")
        #expect(MCPHealthWords.tone(try #require(byName["broken"])) == .failing)
    }

    @Test func checkNowChecksAgainAndAChangedEntryIsCheckedAgain() async throws {
        let w = try await world()
        try #"{"mcpServers": {"echo": \#(echo)}}"#.write(to: w.mcp, atomically: true, encoding: .utf8)
        await w.core.startMCPHealth()
        let first = try await snapshot(w.core) { $0.personal.first?.check == .answered }
        let firstAt = try #require(first.personal.first?.checkedAt)

        try await Task.sleep(for: .milliseconds(20))
        _ = await w.core.mcpHealthCheck(.init(project: nil))
        let again = try await snapshot(w.core) { snapshot in
            snapshot.personal.first?.check == .answered && (snapshot.personal.first?.checkedAt ?? firstAt) > firstAt
        }
        #expect(again.personal.first?.checkedAt.map { $0 > firstAt } == true)

        // An edit that breaks it: checked on the next look, not in four hours.
        try #"{"mcpServers": {"echo": {"command": "no-such-mcp-753"}}}"#.write(to: w.mcp, atomically: true, encoding: .utf8)
        await w.core.reconcileMCPHealth()
        let broken = try await snapshot(w.core) { $0.personal.first?.check == .failed }
        #expect(broken.personal.first?.lastError == "The command was not found.")
        await w.core.stopMCPHealth()
    }

    @Test func aProjectServerWaitingForApprovalIsListedAndNeverStarted() async throws {
        let w = try await world()
        _ = try await w.core.addProject(w.project)
        try await w.core.mcpApprovalStore.save(MCPApprovals(approvalsBegan: Date()))
        try #"{"mcpServers": {"tools": \#(echo)}}"#
            .write(to: MCPJSONFile.projectURL(folder: w.project), atomically: true, encoding: .utf8)
        await w.core.startMCPHealth()
        let path = Project.standardize(w.project).path(percentEncoded: false)
        let done = try await snapshot(w.core) { !$0.servers(in: path).isEmpty }
        await w.core.stopMCPHealth()
        #expect(done.personal.isEmpty)
        #expect(done.servers(in: path).map(\.name) == ["tools"])
        #expect(done.servers(in: path).first?.check == .waiting)
    }

    @Test func anUnreadableFileIsSaidOnce() async throws {
        let w = try await world()
        try "{ not json".write(to: w.mcp, atomically: true, encoding: .utf8)
        let snapshot = await w.core.mcpHealthSnapshot()
        #expect(snapshot.personal.isEmpty)
        #expect(snapshot.problem(in: nil)?.hasPrefix("mcp.json is not valid JSON.") == true)
    }

    @Test func wordsForEachState() {
        func server(_ check: DaemonAPI.MCPCheckState, tools: Int? = nil) -> DaemonAPI.MCPServerHealth {
            .init(name: "s", project: nil, transport: .stdio, check: check,
                  checkedAt: check == .answered || check == .failed ? Date(timeIntervalSince1970: 0) : nil,
                  lastError: check == .failed ? "Nothing answered at that address." : nil, tools: tools)
        }
        #expect(MCPHealthWords.line(server(.unchecked)) == "Not checked yet")
        #expect(MCPHealthWords.line(server(.answered, tools: 3)).hasPrefix("Answered \u{00B7} 3 tools \u{00B7} checked "))
        #expect(MCPHealthWords.line(server(.failed)).hasPrefix("Didn't answer \u{00B7} checked "))
        #expect(MCPHealthWords.lastError(server(.failed)) == "Nothing answered at that address.")
        #expect(MCPHealthWords.lastError(server(.answered)) == nil)
        #expect(MCPHealthWords.kind(server(.answered)) == "stdio \u{00B7} run in each session")
        let hosted = DaemonAPI.MCPServerHealth(name: "h", project: nil, transport: .stdio, hosted: true)
        #expect(MCPHealthWords.line(hosted) == "Hosted \u{00B7} starts on the first call")
        #expect(MCPHealthWords.tone(hosted) == .quiet)
        #expect(MCPHealthWords.tally([]) == nil)
        #expect(MCPHealthWords.tally([server(.answered), server(.unchecked)])?.words == "2 servers")
    }
}
#endif
