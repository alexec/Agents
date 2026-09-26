import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// `~/.agents/mcp.json`, read into the servers a session is given (054, data-model.md
/// `PersonalMCPServer`). A problem says where, and never what: the file holds secrets.
@Suite("Personal MCP servers")
struct PersonalMCPTests {
    private let secret = "SENTINEL-7f3c-do-not-show"

    private func parse(_ text: String) -> Result<[MCPServer], PersonalDotAgents.MCPFileProblem> {
        PersonalDotAgents.parseServers(Data(text.utf8))
    }

    @Test func aCommandMakesAStdioServer() throws {
        let servers = try parse("""
            {"mcpServers": {"github": {"command": "npx", "args": ["-y", "gh"], "env": {"TOKEN": "t"}}}}
            """).get()
        #expect(servers == [MCPServer(name: "github",
                                      transport: .stdio(command: "npx", args: ["-y", "gh"], env: ["TOKEN": "t"]))])
    }

    @Test func aURLIsHttpUnlessItSaysSse() throws {
        let servers = try parse("""
            {"mcpServers": {
              "docs": {"url": "https://a.example/mcp", "headers": {"Authorization": "Bearer x"}},
              "old": {"type": "sse", "url": "https://b.example/sse"}
            }}
            """).get()
        #expect(servers == [
            MCPServer(name: "docs", transport: .http(url: "https://a.example/mcp", headers: ["Authorization": "Bearer x"])),
            MCPServer(name: "old", transport: .sse(url: "https://b.example/sse", headers: [:])),
        ])
    }

    @Test func theFilesOrderIsKept() throws {
        let names = try parse("""
            {"other": {"mcpServers": 1}, "mcpServers": {
              "zeta": {"command": "z", "args": ["{", "}", ","]},
              "alpha": {"url": "u", "headers": {"k": "{\\"v\\""}},
              "mid": {"command": "m"}
            }}
            """).get().map(\.name)
        #expect(names == ["zeta", "alpha", "mid"])
    }

    @Test func noFileAndNoServersAreBothNothing() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "PersonalMCPTests-\(UUID())")
        #expect(try PersonalDotAgents.personalServers(home: home).get() == [])
        #expect(PersonalDotAgents.mcpStamp(home: home) == nil)
        #expect(try parse("{}").get() == [])
        #expect(try parse("  \n").get() == [])
    }

    @Test func anEntryWithNeitherCommandNorURLIsAProblemOnItsLine() {
        guard case .failure(let problem) = parse("{\n  \"mcpServers\": {\n    \"broken\": {\"args\": []}\n  }\n}") else {
            Issue.record("a server with nothing to run was accepted")
            return
        }
        #expect(problem.message.contains("broken"))
        #expect(problem.line == 3)
    }

    @Test func textThatIsNotJSONIsAProblemWithALine() {
        guard case .failure(let problem) = parse("{\n  \"mcpServers\": {\n    \"x\": {\"command\": \"a\",,}\n") else {
            Issue.record("broken JSON was accepted")
            return
        }
        #expect(problem.line == 3)
    }

    // FR-023
    @Test func noProblemEverQuotesAValueFromTheFile() {
        let broken = [
            "{\"mcpServers\": {\"a\": {\"command\": \"x\", \"env\": {\"K\": \"\(secret)\"}, \"args\": [\"\(secret)\"],,}}}",
            "{\"mcpServers\": {\"a\": {\"env\": {\"K\": \"\(secret)\"}, \"args\": [\"\(secret)\"]}}}",
            "{\"mcpServers\": {\"a\": {\"url\": \"https://x/?key=\(secret)\", \"headers\": {\"H\": 1}}}}",
            "{\"mcpServers\": {\"a\": {\"url\": \"https://x/?key=\(secret)\", \"type\": \"\(secret)\"}}}",
            "{\"mcpServers\": {\"a\": {\"command\": \"x\", \"env\": {\"K\": [\"\(secret)\"]}}}}",
            "\(secret) {",
        ]
        for text in broken {
            guard case .failure(let problem) = parse(text) else {
                Issue.record("accepted: \(text.count) bytes")
                continue
            }
            #expect(!problem.message.contains(secret))
            #expect(!problem.message.contains("SENTINEL"))
        }
    }
}
