#if canImport(CryptoKit)
import Foundation
import Testing
@testable import AgentsKit

@Suite("MCP catalogue sidecar")
struct MCPSidecarTests {
    @Test func addRemoveLookup() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "sidecar-\(UUID().uuidString).json")
        var side = MCPCatalogSidecar.load(from: url)
        #expect(side.servers.isEmpty)
        side.upsert(destination: .personal, name: "github",
                    record: .init(registryName: "io.github.github/github-mcp-server",
                                  version: "1.0", run: "remote", addedAt: Date(timeIntervalSince1970: 1)))
        try side.save(to: url)
        let loaded = MCPCatalogSidecar.load(from: url)
        #expect(loaded.record(destination: .personal, name: "github")?.version == "1.0")
        var gone = loaded
        gone.remove(destination: .personal, name: "github")
        try gone.save(to: url)
        #expect(MCPCatalogSidecar.load(from: url).record(destination: .personal, name: "github") == nil)
    }
}
#endif
