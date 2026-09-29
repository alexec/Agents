import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// A project's servers (060, US2): added from the sheet is approved, one that arrives
/// in the file waits, Approve takes the digest it was shown, and a session gets the
/// project's ahead of the person's — unless a secret is still missing.
@Suite("MCP project servers")
struct MCPProjectTests {
    struct World {
        let home: URL
        let project: URL
        let installer: MCPInstaller
        let store: MCPApprovalStore
    }

    func world() throws -> World {
        let root = URL(filePath: NSTemporaryDirectory()).appending(path: "mcp-proj-\(UUID().uuidString)")
        let home = root.appending(path: "home")
        let project = root.appending(path: "project")
        try FileManager.default.createDirectory(at: home.appending(path: ".agents"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        return World(home: home, project: project,
                     installer: MCPInstaller(sidecar: root.appending(path: "catalog-mcp.json"),
                                            approvals: root.appending(path: "mcp-approvals.json")),
                     store: MCPApprovalStore(file: root.appending(path: "mcp-approvals.json")))
    }

    func staged(_ name: String, entry: OrderedJSON, registry: String = "io.github.example/postgres",
                requiresSecret: Bool = true) -> MCPInstaller.Staged {
        let variables: [DaemonAPI.MCPVariable] = requiresSecret
            ? [.init(name: "DATABASE_URL", description: "", kind: .secret, required: true,
                     alreadySet: false, placeholder: nil)]
            : []
        let preview = DaemonAPI.MCPPreview(
            previewID: UUID(),
            result: .init(id: registry, title: name, description: "", version: "0.6.2",
                          publisher: .init(label: "example on GitHub", namespace: "io.github.example", known: false),
                          known: false, runs: [.npx], remoteHost: nil),
            nameHere: name, chosenRun: .npx, commandOrURL: "npx -y pkg", host: nil,
            entry: entry.asJSONObject(),
            variables: variables,
            reach: [:], destinationState: .free, problems: [])
        return .init(preview: preview, entry: entry,
                     transport: .stdio(command: "npx", args: ["-y", "pkg"], env: [:]),
                     registryName: registry, version: "0.6.2")
    }

    func postgresEntry() -> OrderedJSON {
        .mcpEntry(stdio: "npx", args: ["-y", "@modelcontextprotocol/server-postgres@0.6.2", "${DATABASE_URL}"], env: [])
    }

    func list(_ w: World) -> MCPProjectListing.Result {
        MCPProjectListing.list(destination: .project(folder: w.project.path), personalHome: w.home,
                               sidecar: MCPCatalogSidecar.load(from: w.installer.sidecarURL),
                               approvals: w.store.load())
    }

    @Test func digestIgnoresKeyOrder() {
        let a = OrderedJSON.object([("url", .string("https://example")), ("type", .string("http"))])
        let b = OrderedJSON.object([("type", .string("http")), ("url", .string("https://example"))])
        #expect(a.canonicalJSON() == b.canonicalJSON())
        #expect(MCPApprovals.digest(of: a) == MCPApprovals.digest(of: b))
    }

    @Test func addToProjectApprovesAndKeepsTheSecretOutOfTheFile() throws {
        let w = try world()
        try w.store.save(MCPApprovals(approvalsBegan: Date()))
        let entry = postgresEntry()
        let managed = try w.installer.add(staged("postgres", entry: entry),
                                          destination: .project(folder: w.project.path),
                                          personalHome: w.home,
                                          secrets: ["DATABASE_URL": "postgres://local/db"],
                                          plain: [:], replace: false)
        #expect(managed.name == "postgres")

        let text = try String(contentsOf: MCPJSONFile.projectURL(folder: w.project), encoding: .utf8)
        #expect(text.contains("${DATABASE_URL}"))
        #expect(!text.contains("postgres://local/db"))

        let approvals = w.store.load()
        let written = try #require(try MCPJSONFile.entry(named: "postgres", at: MCPJSONFile.projectURL(folder: w.project)))
        #expect(approvals.approved[MCPApprovals.key(folder: w.project, name: "postgres")] == MCPApprovals.digest(of: written))

        let listed = list(w)
        #expect(listed.problem == nil)
        let row = try #require(listed.servers.first)
        #expect(row.name == "postgres")
        #expect(row.approval == .approved)
        #expect(row.managed?.registryName == "io.github.example/postgres")
        #expect(row.missingSecrets.isEmpty)
        #expect(row.summary.contains("${DATABASE_URL}"))
    }

    @Test func aHandWrittenEntryWaitsUntilApprovedWithItsDigest() throws {
        let w = try world()
        try w.store.save(MCPApprovals(approvalsBegan: Date()))
        let entry = postgresEntry()
        try MCPJSONFile.upsert(name: "postgres", entry: entry, at: MCPJSONFile.projectURL(folder: w.project))

        let waiting = list(w)
        let row = try #require(waiting.servers.first)
        guard case .waiting(let digest, let isNew) = row.approval else {
            Issue.record("expected waiting")
            return
        }
        #expect(isNew)
        #expect(digest == MCPApprovals.digest(of: entry))
        #expect(row.managed == nil)

        var approvals = w.store.load()
        try approvals.approve(folder: w.project, name: "postgres", digest: digest, entry: entry)
        try w.store.save(approvals)
        #expect(list(w).servers.first?.approval == .approved)

        let changed = OrderedJSON.mcpEntry(stdio: "npx", args: ["-y", "other@1"], env: [])
        try MCPJSONFile.upsert(name: "postgres", entry: changed, at: MCPJSONFile.projectURL(folder: w.project))
        let again = try #require(list(w).servers.first)
        guard case .waiting(_, let stillNew) = again.approval else {
            Issue.record("expected waiting after the edit")
            return
        }
        #expect(!stillNew)
        #expect(throws: DaemonAPI.MCPCatalogError.staleDigest) {
            try approvals.approve(folder: w.project, name: "postgres", digest: digest, entry: changed)
        }
    }

    @Test func waitingServersAreListedFirst() throws {
        let w = try world()
        try w.store.save(MCPApprovals(approvalsBegan: Date()))
        let entry = postgresEntry()
        _ = try w.installer.add(staged("github", entry: .mcpEntry(http: "https://example", headers: []),
                                      requiresSecret: false),
                                destination: .project(folder: w.project.path), personalHome: w.home,
                                secrets: [:], plain: [:], replace: false)
        try MCPJSONFile.upsert(name: "postgres", entry: entry, at: MCPJSONFile.projectURL(folder: w.project))
        #expect(list(w).servers.map(\.name) == ["postgres", "github"])
    }

    @Test func theProjectsServerBeatsThePersonsOfTheSameName() {
        let app = MCPServer(name: "agents", transport: .stdio(command: "agentsd", args: [], env: [:]))
        let project = MCPServer(name: "github", transport: .stdio(command: "from-project", args: [], env: [:]))
        let personal = MCPServer(name: "github", transport: .stdio(command: "from-you", args: [], env: [:]))
        let plan = SessionServers.plan(app: app, chosen: [], project: [project],
                                       personal: .success([personal, MCPServer(name: "notes", transport: .stdio(command: "notes", args: [], env: [:]))]),
                                       http: true, sse: true)
        #expect(plan.servers.map(\.name) == ["agents", "github", "notes"])
        #expect(plan.servers.map(\.transport) == [app.transport, project.transport,
                                                  MCPServer(name: "notes", transport: .stdio(command: "notes", args: [], env: [:])).transport])
        #expect(plan.dropped.map(\.name) == ["github"])
        #expect(plan.dropped.map(\.reason) == [.nameTaken])
    }

    @Test func aMissingSecretIsListedAndLeftOutOfTheSession() throws {
        let w = try world()
        let entry = postgresEntry()
        try MCPJSONFile.upsert(name: "postgres", entry: entry, at: MCPJSONFile.projectURL(folder: w.project))
        var approvals = MCPApprovals(approvalsBegan: Date())
        approvals.recordAdded(folder: w.project, name: "postgres", entry: entry)

        let row = try #require(MCPProjectListing.list(
            destination: .project(folder: w.project.path), personalHome: w.home,
            sidecar: MCPCatalogSidecar(), approvals: approvals).servers.first)
        #expect(row.missingSecrets == ["DATABASE_URL"])

        let contribution = SessionServers.projectContribution(in: w.project, approvals: approvals,
                                                              secrets: SecretsEnv(lines: []))
        #expect(contribution.servers.isEmpty)
        #expect(contribution.missing.map(\.name) == ["postgres"])
        #expect(contribution.missing.first?.secrets == ["DATABASE_URL"])
        #expect(contribution.waiting.isEmpty)
    }

    @Test func anUnapprovedServerIsNotHandedToASession() throws {
        let w = try world()
        try MCPJSONFile.upsert(name: "postgres", entry: postgresEntry(), at: MCPJSONFile.projectURL(folder: w.project))
        let approvals = MCPApprovals(approvalsBegan: Date())
        let contribution = SessionServers.projectContribution(in: w.project, approvals: approvals,
                                                              secrets: SecretsEnv(lines: []))
        #expect(contribution.servers.isEmpty)
        #expect(contribution.waiting == ["postgres"])
    }
}
