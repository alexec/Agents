#if canImport(CryptoKit)
import Foundation
import Testing
@testable import AgentsKit

@Suite("MCP Registry client")
struct MCPRegistryTests {
    @Test func searchOrderAndShortQuery() async throws {
        let (session, state) = MCPRegistryStub.make()
        let registry = MCPRegistry(session: session, endpoints: MCPRegistryStub.endpoints)
        #expect(try await registry.search("g") == [])
        #expect(state.requests.isEmpty)

        let results = try await registry.search("github")
        #expect(!results.isEmpty)
        #expect(results.contains { $0.id == "io.github.github/github-mcp-server" })
        #expect(results.first { $0.id == "io.github.github/github-mcp-server" }?.known == true)
        #expect(state.requests.count == 1)
    }

    @Test func detailEncodesSlash() async throws {
        let (session, state) = MCPRegistryStub.make()
        let registry = MCPRegistry(session: session, endpoints: MCPRegistryStub.endpoints)
        let server = try await registry.detail("io.github.github/github-mcp-server")
        #expect(server.name == "io.github.github/github-mcp-server")
        #expect(server.remotes?.isEmpty == false)
        let path = state.requests.last?.absoluteString ?? ""
        #expect(path.contains("io.github.github%2Fgithub-mcp-server") || path.contains("github-mcp-server"))
    }

    @Test func unreachableWhenDown() async {
        let (session, state) = MCPRegistryStub.make()
        state.mode = .down
        let registry = MCPRegistry(session: session, endpoints: MCPRegistryStub.endpoints)
        do {
            _ = try await registry.search("github")
            Issue.record("expected unreachable")
        } catch let error as DaemonAPI.MCPCatalogError {
            if case .unreachable = error { } else { Issue.record("wrong error \(error)") }
        } catch {
            Issue.record("wrong type \(error)")
        }
    }
}
#endif
