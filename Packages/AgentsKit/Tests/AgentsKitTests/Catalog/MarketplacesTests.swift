#if canImport(CryptoKit)
import Foundation
import Testing
@testable import AgentsKit
import AgentsKitCore

/// Choosing marketplaces (#687): the provided list, the person's own, a project's, which
/// are on, and what can be added.
@Suite("Marketplaces")
struct MarketplacesTests {
    let noEnvironment: [String: String] = [:]

    @Test func providedListPutsGitHubsRegistryFirst() {
        let mcp = Marketplaces.list(kind: .mcp, personal: .init(), project: nil, secretIsSet: { _ in false },
                                    environment: noEnvironment)
        #expect(mcp.map(\.id) == ["provided:github-mcp", "provided:official-mcp"])
        #expect(mcp.allSatisfy { $0.enabled })
        let skills = Marketplaces.list(kind: .skills, personal: .init(), project: nil, secretIsSet: { _ in false },
                                       environment: noEnvironment)
        #expect(skills.map(\.format) == [.skillsSh, .gitHubSkills])
    }

    @Test func aWalkPointsProvidedRegistriesAtItsFixture() {
        let mcp = Marketplaces.list(kind: .mcp, personal: .init(), project: nil, secretIsSet: { _ in false },
                                    environment: [MCPRegistryEndpoints.variable: "http://127.0.0.1:8932"])
        #expect(mcp.allSatisfy { $0.url == "http://127.0.0.1:8932" })
    }

    @Test func personalComesAfterProvidedAndNamesAMissingToken() {
        let personal = Marketplaces.File(marketplaces: [
            .init(name: "Acme", format: .mcpRegistry, url: "https://mcp.acme.example/", token: "ACME_TOKEN"),
        ])
        let list = Marketplaces.list(kind: .mcp, personal: personal, project: nil, secretIsSet: { _ in false },
                                     environment: noEnvironment)
        let acme = try! #require(list.last)
        #expect(acme.id == "personal:https://mcp.acme.example")
        #expect(acme.origin == .personal)
        #expect(acme.tokenMissing)
        #expect(acme.host == "mcp.acme.example")
    }

    @Test func offTurnsAnyOff() {
        var file = Marketplaces.File()
        let official = Marketplaces.provided(environment: noEnvironment)[1]
        Marketplaces.setEnabled(official, false, in: &file)
        #expect(file.off == ["provided:official-mcp"])
        let list = Marketplaces.list(kind: .mcp, personal: file, project: nil, secretIsSet: { _ in true },
                                     environment: noEnvironment)
        #expect(list.first { $0.id == official.id }?.enabled == false)
        Marketplaces.setEnabled(official, true, in: &file)
        #expect(file.off == nil)
    }

    /// A committed file could send one of the person's secrets anywhere it names.
    @Test func aProjectsMarketplaceStartsOffUntilTheyTurnItOn() {
        let project = Marketplaces.File(marketplaces: [
            .init(name: "Company", format: .mcpRegistry, url: "https://registry.company.example", token: "GITHUB_TOKEN"),
        ])
        var personal = Marketplaces.File()
        var list = Marketplaces.list(kind: .mcp, personal: personal, project: project, secretIsSet: { _ in true },
                                     environment: noEnvironment)
        let company = try! #require(list.last)
        #expect(company.origin == .project)
        #expect(!company.enabled)
        Marketplaces.setEnabled(company, true, in: &personal)
        #expect(personal.on == ["project:https://registry.company.example"])
        list = Marketplaces.list(kind: .mcp, personal: personal, project: project, secretIsSet: { _ in true },
                                 environment: noEnvironment)
        #expect(list.last?.enabled == true)
    }

    @Test func fileRoundTripsAndAnUnreadableOneIsRefused() throws {
        let dir = URL(filePath: NSTemporaryDirectory()).appending(path: "marketplaces-\(UUID().uuidString)")
        let url = dir.appending(path: "marketplaces.json")
        #expect(try Marketplaces.load(url) == Marketplaces.File())
        let file = Marketplaces.File(marketplaces: [.init(name: "Acme", format: .gitHubSkills, url: "acme/skills")],
                                     off: ["provided:skills-sh"])
        try Marketplaces.save(file, to: url)
        #expect(try Marketplaces.load(url) == file)
        try Data("{ not json".utf8).write(to: url)
        #expect(throws: Marketplaces.Unreadable.self) { try Marketplaces.load(url) }
    }

    @Test func whatCanBeAdded() {
        func problem(_ format: DaemonAPI.MarketplaceFormat, _ url: String, token: String? = nil) -> String? {
            Marketplaces.problem(.init(name: "X", format: format, url: url, token: token))
        }
        #expect(problem(.mcpRegistry, "https://mcp.acme.example") == nil)
        #expect(problem(.mcpRegistry, "http://localhost:8080") == nil)
        #expect(problem(.mcpRegistry, "http://mcp.acme.example") != nil)
        #expect(problem(.mcpRegistry, "mcp.acme.example") != nil)
        #expect(problem(.gitHubSkills, "acme/skills") == nil)
        #expect(problem(.gitHubSkills, "https://github.com/acme/skills") != nil)
        #expect(problem(.mcpRegistry, "https://mcp.acme.example", token: "ACME_TOKEN") == nil)
        #expect(problem(.mcpRegistry, "https://mcp.acme.example", token: "acme token") != nil)
        #expect(Marketplaces.problem(.init(name: " ", format: .gitHubSkills, url: "acme/skills")) != nil)
    }

    @Test func registryAsksV01AndSendsItsToken() {
        let endpoints = MCPRegistryEndpoints(base: URL(string: "https://api.mcp.github.com")!, token: "secret")
        #expect(endpoints.searchURL(query: "git").path == "/v0.1/servers")
        #expect(endpoints.detailURL(name: "io.github.github/github-mcp-server").absoluteString
            == "https://api.mcp.github.com/v0.1/servers/io.github.github%2Fgithub-mcp-server/versions/latest")
        let request = endpoints.request(endpoints.searchURL(query: "git"))
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
        #expect(MCPRegistryEndpoints.live.request(endpoints.searchURL(query: "git"))
            .value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func aRepositorysSkillsAreItsSkillFolders() {
        let tree: [GitHubSource.TreeEntry] = [
            .init(path: "README.md", mode: "100644", type: "blob", sha: "a"),
            .init(path: "skills/pdf/SKILL.md", mode: "100644", type: "blob", sha: "b"),
            .init(path: "skills/pdf/scripts/run.sh", mode: "100755", type: "blob", sha: "c"),
            .init(path: "docx/SKILL.md", mode: "100644", type: "blob", sha: "d"),
            .init(path: "bad name/SKILL.md", mode: "100644", type: "blob", sha: "e"),
        ]
        #expect(GitHubSkillsCatalog.skillFolders(tree, repo: "skills").map(\.id) == ["pdf", "docx"])
        #expect(GitHubSkillsCatalog.skillFolders([.init(path: "SKILL.md", mode: "100644", type: "blob", sha: "f")],
                                                 repo: "one-skill").map(\.id) == ["one-skill"])
    }

    @Test func marketplaceMethodsAreAPersons() {
        for method in [DaemonAPI.Method.marketplacesList, DaemonAPI.Method.marketplacesAdd, DaemonAPI.Method.marketplacesRemove,
                       DaemonAPI.Method.marketplacesSetEnabled] {
            #expect(ConnectionRole.control.allows(method))
            #expect(!ConnectionRole.agent.allows(method))
            #expect(!ConnectionRole.stranger.allows(method))
        }
    }
}
#endif
