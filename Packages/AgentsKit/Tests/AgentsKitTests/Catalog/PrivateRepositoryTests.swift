#if canImport(CryptoKit)
import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// A private repository of skills (#697): GitHub refuses every plain read of it, so its
/// commit and files come through the person's `gh`. Against the real GitHub's addresses,
/// which the stub session answers 404 for, as GitHub does a private repository.
@Suite("A private skills repository")
struct PrivateRepositoryTests {
    let m = CatalogStub.meta

    func signedIn() throws -> FakeGitHub {
        let gh = try FakeGitHub()
        try gh.reply(#"{"default_branch":"main","private":true}"#, for: "repos/\(m.owner)/\(m.repo)")
        try gh.reply(#"{"ref":"refs/heads/main","object":{"sha":"\#(m.commit)","type":"commit"}}"#,
                     for: "repos/\(m.owner)/\(m.repo)/git/ref/heads/main")
        return gh
    }

    @Test func theCommitComesThroughGhWhenTheRefListIsRefused() async throws {
        let gh = try signedIn()
        let (session, _) = CatalogStub.make()
        let head = try await GitHubSource(session: session, endpoints: .live, gh: gh.cli).head(owner: m.owner, repo: m.repo)
        #expect(head == .init(commit: m.commit, branch: "main", signedIn: true))
    }

    @Test func aPublicRepositoryNeverAsksGh() async throws {
        let gh = try signedIn()
        let (session, state) = CatalogStub.make()
        let refs = try Data(contentsOf: CatalogStub.http.appending(path: "info-refs.txt"))
        state.override("/\(m.owner)/\(m.repo).git/info/refs?service=git-upload-pack", body: refs)
        let head = try await GitHubSource(session: session, endpoints: .live, gh: gh.cli).head(owner: m.owner, repo: m.repo)
        #expect(head == .init(commit: m.commit, branch: "main"))
        #expect(gh.calledWith().isEmpty)
    }

    @Test func withoutAccessItIsUnreachableAsBefore() async throws {
        let (session, _) = CatalogStub.make()
        await #expect(throws: DaemonAPI.CatalogError.unreachable(host: "github.com")) {
            try await GitHubSource(session: session, endpoints: .live, gh: nil).head(owner: m.owner, repo: m.repo)
        }
        // A gh that is not signed in, or cannot see the repository, answers 404 too.
        let gh = try FakeGitHub()
        try gh.reply("{}", for: "elsewhere")
        await #expect(throws: DaemonAPI.CatalogError.unreachable(host: "github.com")) {
            try await GitHubSource(session: session, endpoints: .live, gh: gh.cli).head(owner: m.owner, repo: m.repo)
        }
    }

    /// The whole preview: commit, tree and every file through `gh`, none from the raw host.
    @Test func aPreviewReadsEveryFileThroughGh() async throws {
        let gh = try signedIn()
        let tree = try Data(contentsOf: CatalogStub.http.appending(path: "tree.json"))
        try gh.reply(String(decoding: tree, as: UTF8.self),
                     for: "repos/\(m.owner)/\(m.repo)/git/trees/\(m.commit)?recursive=1")
        struct Answer: Decodable { var tree: [GitHubSource.TreeEntry] }
        let files = CatalogStub.skills.deletingLastPathComponent()
        // GitHub wraps a blob's base64 every 60 characters, so the read must not mind lines.
        for entry in try JSONDecoder().decode(Answer.self, from: tree).tree where entry.type == "blob" && entry.path.hasPrefix("skills/plain/") {
            let bytes = try Data(contentsOf: files.appending(path: entry.path))
            try gh.reply(#"{"sha":"\#(entry.sha)","encoding":"base64","content":"\#(bytes.base64EncodedString(options: .lineLength76Characters).replacingOccurrences(of: "\r\n", with: "\\n"))"}"#,
                         for: "repos/\(m.owner)/\(m.repo)/git/blobs/\(entry.sha)")
        }
        let (session, state) = CatalogStub.make()
        let previewer = SkillPreviewer(catalog: nil, github: GitHubSource(session: session, endpoints: .live, gh: gh.cli))
        let staging = URL(filePath: NSTemporaryDirectory()).appending(path: "private-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staging) }
        let result = DaemonAPI.CatalogResult(id: "\(m.owner)/\(m.repo)/plain", name: "plain", owner: m.owner, repo: m.repo,
                                             skillID: "plain", installs: 0, known: false, marketplace: "personal:acme",
                                             skillPath: "skills/plain/SKILL.md")
        let p = try await previewer.stage(result, into: staging, id: UUID()).preview
        #expect(p.canAdd)
        #expect(p.commit == m.commit)
        #expect(Set(p.files.map(\.path)) == ["SKILL.md", "notes.md"])
        #expect(p.files.allSatisfy { $0.via == "gh" })
        #expect(!state.requests.contains { $0.host == "raw.githubusercontent.com" })
    }
}
#endif
