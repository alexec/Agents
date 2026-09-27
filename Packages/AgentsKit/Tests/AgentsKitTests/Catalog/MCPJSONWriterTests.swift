#if canImport(CryptoKit)
import Foundation
import Testing
@testable import AgentsKit

@Suite("mcp.json writer")
struct MCPJSONWriterTests {
    @Test func spliceKeepsHandWrittenOrder() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "mcpjson-\(UUID().uuidString)")
        let url = dir.appending(path: "mcp.json")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let existing = """
        {
          "mcpServers": {
            "notes": {
              "command": "node",
              "args": ["notes.js"]
            },
            "alpha": {
              "command": "a"
            }
          }
        }
        """
        try Data(existing.utf8).write(to: url)

        let entry = OrderedJSON.mcpEntry(http: "https://api.example/mcp",
                                         headers: [("Authorization", "Bearer ${TOKEN}")])
        try MCPJSONFile.upsert(name: "github", entry: entry, at: url)

        let root = try OrderedJSON.parse(Data(contentsOf: url))
        let names = root["mcpServers"]?.objectPairs?.map(\.0)
        #expect(names == ["notes", "alpha", "github"])
        #expect(root["mcpServers"]?["notes"]?["command"]?.stringValue == "node")
        #expect(root["mcpServers"]?["github"]?["url"]?.stringValue == "https://api.example/mcp")
    }

    @Test func refuseInvalidJSON() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "mcpjson-\(UUID().uuidString)")
        let url = dir.appending(path: "mcp.json")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: url)
        #expect(throws: MCPJSONFile.Problem.self) {
            try MCPJSONFile.upsert(name: "x", entry: .object([]), at: url)
        }
    }

    @Test func projectPath() {
        let folder = URL(filePath: "/tmp/proj")
        #expect(MCPJSONFile.projectURL(folder: folder).path.hasSuffix("/tmp/proj/.agents/mcp.json"))
    }
}
#endif
