#if canImport(CryptoKit)
import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

@Suite("MCP preview and add")
struct MCPPreviewAndAddTests {
    struct World {
        let root: URL
        let home: URL
        let session: URLSession
        let installer: MCPInstaller
        let registry: MCPRegistry
    }

    func world() throws -> World {
        let root = URL(filePath: NSTemporaryDirectory()).appending(path: "mcp-\(UUID().uuidString)")
        let home = root.appending(path: "home")
        try FileManager.default.createDirectory(at: home.appending(path: ".agents"), withIntermediateDirectories: true)
        let (session, _) = MCPRegistryStub.make()
        return World(root: root, home: home, session: session,
                     installer: MCPInstaller(sidecar: root.appending(path: "catalog-mcp.json")),
                     registry: MCPRegistry(session: session, endpoints: MCPRegistryStub.endpoints))
    }

    @Test func previewAndAddPersonal() async throws {
        let w = try world()
        let detail = try await w.registry.detail("io.github.github/github-mcp-server")
        let result = MCPRegistry.result(from: detail)
        let built = try MCPEntryBuilder.build(detail, run: .remote)
        let previewID = UUID()
        let preview = DaemonAPI.MCPPreview(
            previewID: previewID, result: result, nameHere: built.nameHere, chosenRun: .remote,
            commandOrURL: built.commandOrURL, host: built.hostLabel, entry: built.entry.asJSONObject(),
            variables: built.variables, reach: [:], destinationState: .free, problems: [])
        let staged = MCPInstaller.Staged(preview: preview, entry: built.entry, transport: built.transport,
                                         registryName: detail.name, version: detail.version ?? "")
        let managed = try w.installer.add(staged, destination: .personal, personalHome: w.home,
                                          secrets: ["GITHUB_TOKEN": "ghp_test_not_real"], plain: [:], replace: false)
        #expect(managed.name == "github")

        let mcpURL = MCPJSONFile.personalURL(home: w.home)
        let text = try String(contentsOf: mcpURL, encoding: .utf8)
        #expect(text.contains("${GITHUB_TOKEN}"))
        #expect(!text.contains("ghp_test_not_real"))

        let secrets = SecretsEnv.load(from: SecretsEnv.url(home: w.home))
        #expect(secrets.value(of: "GITHUB_TOKEN") == "ghp_test_not_real")
        let attrs = try FileManager.default.attributesOfItem(atPath: SecretsEnv.url(home: w.home).path)
        #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)

        #expect(MCPCatalogSidecar.load(from: w.installer.sidecarURL)
            .record(destination: .personal, name: "github")?.registryName == detail.name)

        let servers: [MCPServer]
        switch PersonalDotAgents.personalServers(home: w.home) {
        case .success(let s): servers = s
        case .failure(let e): Issue.record("\(e)"); return
        }
        #expect(servers.contains { $0.name == "github" })
        let filled = secrets.filled(servers.first { $0.name == "github" }!)
        if case .http(_, let headers) = filled?.transport {
            #expect(headers["Authorization"] == "Bearer ghp_test_not_real")
        } else { Issue.record("expected http") }

        let missing = SecretsEnv(lines: [])
        #expect(missing.filled(servers.first { $0.name == "github" }!) == nil)
    }

    @Test func refuseUnmanagedName() throws {
        let w = try world()
        let url = MCPJSONFile.personalURL(home: w.home)
        try MCPJSONFile.upsert(name: "github",
                               entry: OrderedJSON.mcpEntry(stdio: "node", args: ["x"], env: []),
                               at: url)
        let entry = OrderedJSON.mcpEntry(http: "https://example", headers: [("Authorization", "Bearer ${T}")])
        let preview = DaemonAPI.MCPPreview(
            previewID: UUID(),
            result: .init(id: "x", title: "GitHub", description: "", version: "1",
                          publisher: .init(label: "x", namespace: "x", known: false), known: false,
                          runs: [.remote], remoteHost: nil),
            nameHere: "github", chosenRun: .remote, commandOrURL: "https://example", host: nil,
            entry: entry.asJSONObject(), variables: [], reach: [:], destinationState: .free, problems: [])
        let staged = MCPInstaller.Staged(preview: preview, entry: entry,
                                         transport: .http(url: "https://example", headers: [:]),
                                         registryName: "io.github.github/github-mcp-server", version: "1")
        #expect(throws: DaemonAPI.MCPCatalogError.self) {
            try w.installer.add(staged, destination: .personal, personalHome: w.home,
                                secrets: ["T": "v"], plain: [:], replace: false)
        }
    }
}
#endif
