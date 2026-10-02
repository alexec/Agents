#if canImport(CryptoKit)
import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// The catalogue and GitHub, against the recorded fixtures (059, tasks T011, T012).
@Suite("Catalogue sources")
struct CatalogSourcesTests {
    let m = CatalogStub.meta

    // MARK: skills.sh

    @Test func searchKeepsTheCataloguesOrderAndOnlyGitHub() async throws {
        let (session, _) = CatalogStub.make()
        let results = try await SkillsCatalog(session: session, endpoints: CatalogStub.endpoints).search("fixture")
        #expect(results.map(\.skillID) == ["nested", "plain", "mixed"])
        #expect(results.map(\.installs) == [5120, 812, 42])
        try #require(!results.isEmpty)
        #expect(results[0].owner == "fixture-owner" && results[0].repo == "fixture-skills")
    }

    @Test func knownIsOnlyForTheShortListAndIgnoresCase() async throws {
        let (session, _) = CatalogStub.make()
        let results = try await SkillsCatalog(session: session, endpoints: CatalogStub.endpoints).search("fixture")
        #expect(results.map(\.known) == [false, false, true])
    }

    @Test func aShortQueryIsNotSent() async throws {
        let (session, state) = CatalogStub.make()
        #expect(try await SkillsCatalog(session: session, endpoints: CatalogStub.endpoints).search(" a ").isEmpty)
        #expect(state.requests.isEmpty)
    }

    @Test func downIsUnreachableNotEmpty() async {
        let (session, state) = CatalogStub.make()
        state.mode = .down
        await #expect(throws: DaemonAPI.CatalogError.unreachable(host: "skills.test")) {
            try await SkillsCatalog(session: session, endpoints: CatalogStub.endpoints).search("fixture")
        }
    }

    @Test func theRealAnswerParses() throws {
        struct Answer: Decodable { struct Row: Decodable { var source: String; var skillId: String }; var skills: [Row] }
        let data = try Data(contentsOf: CatalogStub.http.appending(path: "search-swiftui.json"))
        let rows = try JSONDecoder().decode(Answer.self, from: data).skills
        #expect(!rows.isEmpty)
        #expect(rows.allSatisfy { SkillsCatalog.gitHubSource($0.source) != nil })
    }

    @Test func onlyOwnerSlashRepoIsGitHub() {
        #expect(SkillsCatalog.gitHubSource("avdlee/swiftui-agent-skill") != nil)
        #expect(SkillsCatalog.gitHubSource("https://www.notion.so/.well-known/skills") == nil)
        #expect(SkillsCatalog.gitHubSource("a/b/c") == nil)
        #expect(SkillsCatalog.gitHubSource("../etc") == nil)
    }

    @Test func endpointsMoveToAFixtureServer() {
        let e = CatalogEndpoints.from(environment: ["AGENTS_TEST_CATALOG_URL": "http://127.0.0.1:8931",
                                                     "AGENTS_TEST_GITHUB_URL": "http://127.0.0.1:8931"])
        #expect(e.catalog.absoluteString == "http://127.0.0.1:8931")
        #expect(e.api.absoluteString == "http://127.0.0.1:8931/api")
        #expect(e.raw.absoluteString == "http://127.0.0.1:8931/raw")
        #expect(!e.isLive)
        #expect(CatalogEndpoints.from(environment: [:]).isLive)
    }

    // MARK: GitHub

    @Test func headAndBranchComeFromTheRefList() async throws {
        let (session, _) = CatalogStub.make()
        let head = try await GitHubSource(session: session, endpoints: CatalogStub.endpoints, gh: nil)
            .head(owner: m.owner, repo: m.repo)
        #expect(head == .init(commit: m.commit, branch: "main"))
    }

    @Test func aRealRefListParses() {
        let real = "001e# service=git-upload-pack\n00000159b24e68a965dc4b5bd2cc41dc60c094a26a9379ce HEAD\0multi_ack symref=HEAD:refs/heads/main filter\n0044"
        #expect(GitHubSource.parseRefs(Data(real.utf8)) == .init(commit: "b24e68a965dc4b5bd2cc41dc60c094a26a9379ce", branch: "main"))
    }

    @Test func theTreeIsTheCommitsAndRawIsAtTheCommit() async throws {
        let (session, state) = CatalogStub.make()
        let source = GitHubSource(session: session, endpoints: CatalogStub.endpoints, gh: nil)
        let tree = try await source.tree(owner: m.owner, repo: m.repo, commit: m.commit)
        #expect(tree.contains { $0.path == "skills/nested/scripts/lint.sh" && $0.mode == "100755" })
        let data = try await source.raw(owner: m.owner, repo: m.repo, commit: m.commit, path: "skills/nested/assets/logo.png")
        #expect(data.count == 264)
        #expect(state.requests.last?.path == "/\(m.owner)/\(m.repo)/\(m.commit)/skills/nested/assets/logo.png")
    }

    @Test func rateLimitedSaysSo() async {
        let (session, state) = CatalogStub.make()
        state.mode = .rateLimited
        await #expect(throws: GitHubSource.RateLimited.self) {
            try await GitHubSource(session: session, endpoints: CatalogStub.endpoints, gh: nil)
                .tree(owner: m.owner, repo: m.repo, commit: m.commit)
        }
    }

    /// The fallback's tree matches the API's, blob for blob, so a preview does not care which.
    @Test func theTarballsTreeIsTheAPIs() async throws {
        let (session, _) = CatalogStub.make()
        let source = GitHubSource(session: session, endpoints: CatalogStub.endpoints, gh: nil)
        let work = URL(filePath: NSTemporaryDirectory()).appending(path: "tar-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: work) }
        let (_, fromTar) = try await source.tarballTree(owner: m.owner, repo: m.repo, commit: m.commit, into: work)
        let fromAPI = try await source.tree(owner: m.owner, repo: m.repo, commit: m.commit)
        let blobs = { (t: [GitHubSource.TreeEntry]) in
            Dictionary(uniqueKeysWithValues: t.filter { $0.type == "blob" }.map { ($0.path, "\($0.mode) \($0.sha)") })
        }
        #expect(blobs(fromTar) == blobs(fromAPI))
    }

    @Test func aSignedInGhFetchesTheTreeOnlyAgainstTheRealGitHub() async throws {
        let gh = try FakeGitHub()
        try gh.reply(String(decoding: try Data(contentsOf: CatalogStub.http.appending(path: "tree.json")), as: UTF8.self))
        let (session, state) = CatalogStub.make()
        // Pointed at the stub: gh is never asked, whatever is passed.
        _ = try await GitHubSource(session: session, endpoints: CatalogStub.endpoints, gh: gh.cli)
            .tree(owner: m.owner, repo: m.repo, commit: m.commit)
        #expect(gh.calledWith().isEmpty)
        #expect(state.requests.count == 1)
    }
}
#endif
