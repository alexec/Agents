#if canImport(CryptoKit)
import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// Adding a skill to a project or one of its worktrees, and listing a project's skills
/// (059, tasks T035, T036).
@Suite("Skills in a project")
struct SkillProjectTests {
    let m = CatalogStub.meta

    struct World {
        let root: URL
        let project: URL
        let previewer: SkillPreviewer
        let installer: SkillInstaller

        func place(_ folder: URL) throws -> SkillPlace {
            try SkillPlace.resolve(.project(folder: folder.path), personalHome: nil, root: root, usesRealTrash: false,
                                   environment: [:], isProject: { _ in true })
        }
    }

    func world() async throws -> World {
        let root = URL(filePath: NSTemporaryDirectory()).appending(path: "catalog-project-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        let project = root.appending(path: "work")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        _ = try await GitProcess(["-c", "core.fsmonitor=false", "init", "-q"], in: project).run()
        let (session, _) = CatalogStub.make()
        return World(root: root, project: project,
                     previewer: SkillPreviewer(catalog: SkillsCatalog(session: session, endpoints: CatalogStub.endpoints),
                                               github: GitHubSource(session: session, endpoints: CatalogStub.endpoints, gh: nil)),
                     installer: SkillInstaller(sidecar: root.appending(path: "catalog-skills.json")))
    }

    func stage(_ w: World, _ id: String) async throws -> StagedSkill {
        let previewID = UUID()
        let result = DaemonAPI.CatalogResult(id: "\(m.owner)/\(m.repo)/\(id)", name: id, owner: m.owner, repo: m.repo,
                                             skillID: id, installs: 1, known: false)
        return try await w.previewer.stage(result, into: w.root.appending(path: "staging/\(previewID)"), id: previewID)
    }

    @Test func addingToAProjectWritesItsFolderAndItsLockAndCommitsNothing() async throws {
        let w = try await world()
        let place = try w.place(w.project)
        _ = try w.installer.add(try await stage(w, "nested"), to: place, replace: false)

        let folder = w.project.appending(path: ".agents/skills/nested")
        let golden = try #require(try SkillHashesTests.golden().fixtures["nested"])
        #expect(try SkillHashes.computedHash(folder: folder) == golden.computedHash)
        let lock = try SkillLock.load(.project, at: w.project.appending(path: "skills-lock.json"))
        #expect(lock.entry("nested")?.computedHash == golden.computedHash)
        #expect(lock.entry("nested")?.source == "\(m.owner)/\(m.repo)")
        // Claude reads a project's skills through .claude/skills, made where there was none.
        let link = try FileManager.default.destinationOfSymbolicLink(atPath: w.project.appending(path: ".claude/skills").path)
        #expect(link == "../.agents/skills")

        let status = try await GitProcess(["-c", "core.fsmonitor=false", "status", "--porcelain", "--untracked-files=all"],
                                          in: w.project).run()
        #expect(status.output.contains("?? .agents/skills/nested/SKILL.md"))
        #expect(status.output.contains("?? skills-lock.json"))
        #expect(!status.output.contains("A "))  // nothing staged
        let log = try await GitProcess(["-c", "core.fsmonitor=false", "log", "--oneline"], in: w.project).run()
        #expect(!log.succeeded || log.output.isEmpty)  // no commit made
    }

    @Test func anExistingClaudeSkillsFolderIsLeftAlone() async throws {
        let w = try await world()
        let mine = w.project.appending(path: ".claude/skills")
        try FileManager.default.createDirectory(at: mine, withIntermediateDirectories: true)
        _ = try w.installer.add(try await stage(w, "plain"), to: try w.place(w.project), replace: false)
        let values = try mine.resourceValues(forKeys: [.isSymbolicLinkKey])
        #expect(values.isSymbolicLink == false)
    }

    @Test func aWorktreeGetsItsOwnCopy() async throws {
        let w = try await world()
        let worktree = w.project.appending(path: ".agents/worktrees/lane")
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        _ = try w.installer.add(try await stage(w, "plain"), to: try w.place(worktree), replace: false)
        #expect(FileManager.default.fileExists(atPath: worktree.appending(path: ".agents/skills/plain/SKILL.md").path))
        #expect(FileManager.default.fileExists(atPath: worktree.appending(path: "skills-lock.json").path))
        #expect(!FileManager.default.fileExists(atPath: w.project.appending(path: ".agents/skills/plain").path))
    }

    @Test func theListHasEverySkillAndSaysWhichCameFromACatalogue() async throws {
        let w = try await world()
        let place = try w.place(w.project)
        #expect(w.installer.list(at: place).isEmpty)  // no .agents/skills yet: empty, not an error

        let mine = place.skills.appending(path: "run-app")
        try FileManager.default.createDirectory(at: mine, withIntermediateDirectories: true)
        try "---\nname: run-app\ndescription: Build and drive the app.\n---\n"
            .write(to: mine.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: place.skills.appending(path: "not-a-skill"), withIntermediateDirectories: true)
        _ = try w.installer.add(try await stage(w, "nested"), to: place, replace: false)

        let listed = w.installer.list(at: place)
        #expect(listed.map(\.name) == ["nested", "run-app"])
        #expect(listed.first { $0.name == "run-app" }?.managed == nil)
        #expect(listed.first { $0.name == "run-app" }?.description == "Build and drive the app.")
        #expect(listed.first { $0.name == "nested" }?.managed?.commit == m.commit)
    }

    @Test func aProjectFolderIsAKnownProjectOrAWorktreeOfOne() {
        let project = URL(filePath: "/tmp/p")
        let records = [Project.standardize(project): Project(folder: project, addedAt: Date())]
        #expect(DaemonCore.isProjectFolder(project, records: records, agentFolders: []))
        #expect(DaemonCore.isProjectFolder(URL(filePath: "/tmp/p/.agents/worktrees/lane"), records: records, agentFolders: []))
        #expect(!DaemonCore.isProjectFolder(URL(filePath: "/tmp/elsewhere"), records: records, agentFolders: []))
    }
}
#endif
