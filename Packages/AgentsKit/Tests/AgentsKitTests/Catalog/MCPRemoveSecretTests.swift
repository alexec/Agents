import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// Setting a secret, and removing a server the app added (060, US3).
@Suite("MCP remove and set-secret")
struct MCPRemoveSecretTests {
    struct World {
        let home: URL
        let project: URL
        let installer: MCPInstaller
    }

    func world() throws -> World {
        let root = URL(filePath: NSTemporaryDirectory()).appending(path: "mcp-rm-\(UUID().uuidString)")
        let home = root.appending(path: "home")
        let project = root.appending(path: "project")
        try FileManager.default.createDirectory(at: home.appending(path: ".agents"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        return World(home: home, project: project,
                     installer: MCPInstaller(sidecar: root.appending(path: "catalog-mcp.json"),
                                            approvals: root.appending(path: "mcp-approvals.json")))
    }

    func staged(_ name: String, entry: OrderedJSON, secret: String = "DATABASE_URL") -> MCPInstaller.Staged {
        let preview = DaemonAPI.MCPPreview(
            previewID: UUID(),
            result: .init(id: "io.github.example/\(name)", title: name, description: "", version: "1",
                          publisher: .init(label: "example on GitHub", namespace: "io.github.example", known: false),
                          known: false, runs: [.npx], remoteHost: nil),
            nameHere: name, chosenRun: .npx, commandOrURL: "npx -y pkg", host: nil,
            entry: entry.asJSONObject(),
            variables: [.init(name: secret, description: "", kind: .secret, required: true,
                              alreadySet: false, placeholder: nil)],
            reach: [:], destinationState: .free, problems: [])
        return .init(preview: preview, entry: entry,
                     transport: .stdio(command: "npx", args: ["-y", "pkg"], env: [:]),
                     registryName: "io.github.example/\(name)", version: "1")
    }

    func entry(_ secret: String = "DATABASE_URL") -> OrderedJSON {
        .mcpEntry(stdio: "npx", args: ["-y", "pkg", "${\(secret)}"], env: [])
    }

    func secrets(_ w: World) -> SecretsEnv {
        SecretsEnv.load(from: SecretsEnv.url(home: w.home))
    }

    func text(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    @Test func setSecretWritesTheValueAndKeepsTheOthers() throws {
        let w = try world()
        try w.installer.setSecret(name: "DATABASE_URL", value: "postgres://local/db", personalHome: w.home)
        try w.installer.setSecret(name: "CONTEXT7_API_KEY", value: "key=with=equals", personalHome: w.home)
        try w.installer.setSecret(name: "DATABASE_URL", value: "postgres://other", personalHome: w.home)

        let env = secrets(w)
        #expect(env.value(of: "DATABASE_URL") == "postgres://other")
        #expect(env.value(of: "CONTEXT7_API_KEY") == "key=with=equals")
        let attrs = try FileManager.default.attributesOfItem(atPath: SecretsEnv.url(home: w.home).path)
        #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func aSecretNeedsANameAndAValue() throws {
        let w = try world()
        #expect(throws: DaemonAPI.MCPCatalogError.failed("A secret needs a value.")) {
            try w.installer.setSecret(name: "DATABASE_URL", value: "", personalHome: w.home)
        }
        #expect(throws: DaemonAPI.MCPCatalogError.self) {
            try w.installer.setSecret(name: "NOT A NAME", value: "x", personalHome: w.home)
        }
        #expect(!FileManager.default.fileExists(atPath: SecretsEnv.url(home: w.home).path))
    }

    @Test func removeManagedLeavesTheSecretUnlessAsked() throws {
        let w = try world()
        _ = try w.installer.add(staged("postgres", entry: entry()), destination: .personal,
                                personalHome: w.home, secrets: ["DATABASE_URL": "postgres://local/db"],
                                plain: [:], replace: false)
        try w.installer.remove("postgres", destination: .personal, personalHome: w.home, forgetSecret: nil)

        let file = MCPJSONFile.personalURL(home: w.home)
        #expect(try text(file).contains("postgres") == false)
        #expect(MCPCatalogSidecar.load(from: w.installer.sidecarURL).record(destination: .personal, name: "postgres") == nil)
        #expect(secrets(w).value(of: "DATABASE_URL") == "postgres://local/db")
    }

    @Test func removeRefusesAServerThePersonWrote() throws {
        let w = try world()
        let file = MCPJSONFile.personalURL(home: w.home)
        try MCPJSONFile.upsert(name: "postgres", entry: entry(), at: file)
        let before = try text(file)
        #expect(throws: DaemonAPI.MCPCatalogError.unmanaged(path: file.path)) {
            try w.installer.remove("postgres", destination: .personal, personalHome: w.home, forgetSecret: nil)
        }
        #expect(try text(file) == before)
    }

    @Test func forgetSecretOnlyWhenNothingElseNamesIt() throws {
        let w = try world()
        _ = try w.installer.add(staged("postgres", entry: entry()), destination: .personal,
                                personalHome: w.home, secrets: ["DATABASE_URL": "postgres://local/db"],
                                plain: [:], replace: false)
        try w.installer.remove("postgres", destination: .personal, personalHome: w.home, forgetSecret: "DATABASE_URL")
        #expect(secrets(w).value(of: "DATABASE_URL") == nil)

        _ = try w.installer.add(staged("postgres", entry: entry()), destination: .personal,
                                personalHome: w.home, secrets: ["DATABASE_URL": "postgres://local/db"],
                                plain: [:], replace: false)
        try MCPJSONFile.upsert(name: "notes", entry: entry(), at: MCPJSONFile.personalURL(home: w.home))
        #expect(throws: DaemonAPI.MCPCatalogError.secretStillInUse(name: "DATABASE_URL")) {
            try w.installer.remove("postgres", destination: .personal, personalHome: w.home,
                                   forgetSecret: "DATABASE_URL")
        }
        let file = try text(MCPJSONFile.personalURL(home: w.home))
        #expect(file.contains("\"postgres\""))
        #expect(secrets(w).value(of: "DATABASE_URL") == "postgres://local/db")
    }

    @Test func aProjectServerCannotForgetASecretYouStillUse() throws {
        let w = try world()
        _ = try w.installer.add(staged("notes", entry: entry()), destination: .personal,
                                personalHome: w.home, secrets: ["DATABASE_URL": "postgres://local/db"],
                                plain: [:], replace: false)
        _ = try w.installer.add(staged("postgres", entry: entry()),
                                destination: .project(folder: w.project.path),
                                personalHome: w.home, secrets: [:], plain: [:], replace: false)
        let store = MCPApprovalStore(file: w.installer.approvalsURL)
        let key = MCPApprovals.key(folder: w.project, name: "postgres")
        #expect(store.load().approved[key] != nil)

        #expect(throws: DaemonAPI.MCPCatalogError.secretStillInUse(name: "DATABASE_URL")) {
            try w.installer.remove("postgres", destination: .project(folder: w.project.path),
                                   personalHome: w.home, forgetSecret: "DATABASE_URL")
        }
        #expect(try text(MCPJSONFile.projectURL(folder: w.project)).contains("\"postgres\""))

        try w.installer.remove("postgres", destination: .project(folder: w.project.path),
                               personalHome: w.home, forgetSecret: nil)
        #expect(try text(MCPJSONFile.projectURL(folder: w.project)).contains("\"postgres\"") == false)
        #expect(store.load().approved[key] == nil)
        #expect(secrets(w).value(of: "DATABASE_URL") == "postgres://local/db")
    }
}
