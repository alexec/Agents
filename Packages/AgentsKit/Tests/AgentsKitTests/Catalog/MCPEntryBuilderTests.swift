#if canImport(CryptoKit)
import Foundation
import Testing
@testable import AgentsKit

@Suite("MCP entry builder")
struct MCPEntryBuilderTests {
    private func loadDetail(_ file: String) throws -> MCPRegistry.RegistryServer {
        let url = MCPRegistryStub.http.appending(path: file)
        return try JSONDecoder().decode(MCPRegistry.DetailResponse.self, from: Data(contentsOf: url)).server
    }

    @Test func remoteGitHubUsesToken() throws {
        let server = try loadDetail("detail-io.github.github__github-mcp-server.json")
        let built = try MCPEntryBuilder.build(server, run: .remote)
        #expect(built.nameHere == "github")
        #expect(built.commandOrURL.contains("api.githubcopilot.com"))
        #expect(built.variables.contains { $0.name == "GITHUB_TOKEN" && $0.kind == .secret })
        #expect(built.entry.asJSONObject()["headers"] != nil)
        if case .http(_, let headers) = built.transport {
            #expect(headers["Authorization"] == "Bearer ${GITHUB_TOKEN}")
        } else { Issue.record("expected http") }
    }

    @Test func npmPinsVersion() throws {
        let server = try loadDetail("detail-io.github.gitHubDujianfeng__duke-book.json")
        let built = try MCPEntryBuilder.build(server, run: .npx, secretsAlreadySet: { _ in false })
        #expect(built.commandOrURL.hasPrefix("npx -y duke-book@"))
        #expect(built.variables.contains { $0.name == "DUKE_API_TOKEN" && $0.required })
    }

    @Test func context7RemoteAndSkipMcpb() throws {
        let server = try loadDetail("detail-io.github.upstash__context7.json")
        let runs = MCPEntryBuilder.availableRuns(server, onMac: .all)
        #expect(runs.available.contains(.remote))
        #expect(runs.available.contains(.npx))
        #expect(!runs.available.contains(.docker)) // no oci in this entry
        let built = try MCPEntryBuilder.build(server, run: .remote)
        #expect(built.variables.contains { $0.name == "CONTEXT7_API_KEY" })
    }

    @Test func smitheryForeignHost() throws {
        let server = try loadDetail("detail-ai.smithery__Hint-Services-obsidian-github-mcp.json")
        let runs = MCPEntryBuilder.availableRuns(server, onMac: .all)
        #expect(runs.foreignRemoteHost == "server.smithery.ai")
        let built = try MCPEntryBuilder.build(server, run: .remote)
        #expect(built.hostLabel?.contains("not the publisher") == true)
    }

    @Test func dockerUnavailableOnMac() throws {
        let server = try loadDetail("detail-io.github.github__github-mcp-server.json")
        let runs = MCPEntryBuilder.availableRuns(server, onMac: MacTools(npx: false, uvx: false, docker: false))
        #expect(runs.available.contains(.remote))
        #expect(runs.unavailable.contains(.docker))
    }

    private typealias MacTools = MCPEntryBuilder.MacTools
}
#endif
