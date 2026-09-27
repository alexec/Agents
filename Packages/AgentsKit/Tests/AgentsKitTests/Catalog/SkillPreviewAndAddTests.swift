#if canImport(CryptoKit)
import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// A preview, staged from the recorded fixtures, and adding it to the person (059, tasks
/// T010, T023, T024).
@Suite("Previewing and adding a skill")
struct SkillPreviewAndAddTests {
    let m = CatalogStub.meta

    struct World {
        let root: URL
        let home: URL
        let session: URLSession
        let state: CatalogStub.State
        let previewer: SkillPreviewer
        let installer: SkillInstaller
        var personal: SkillPlace {
            try! SkillPlace.resolve(.personal, personalHome: home, root: root, usesRealTrash: false,
                                    environment: [:], isProject: { _ in false })
        }
        var staging: URL { root.appending(path: "catalog-staging") }
    }

    func world() throws -> World {
        let root = URL(filePath: NSTemporaryDirectory()).appending(path: "catalog-\(UUID().uuidString)")
        let home = root.appending(path: "home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let (session, state) = CatalogStub.make()
        let previewer = SkillPreviewer(catalog: SkillsCatalog(session: session, endpoints: CatalogStub.endpoints),
                                       github: GitHubSource(session: session, endpoints: CatalogStub.endpoints, gh: nil))
        return World(root: root, home: home, session: session, state: state, previewer: previewer,
                     installer: SkillInstaller(sidecar: root.appending(path: "catalog-skills.json")))
    }

    func result(_ id: String) -> DaemonAPI.CatalogResult {
        .init(id: "\(m.owner)/\(m.repo)/\(id)", name: id, owner: m.owner, repo: m.repo, skillID: id, installs: 1, known: false)
    }

    func stage(_ w: World, _ id: String) async throws -> StagedSkill {
        let previewID = UUID()
        return try await w.previewer.stage(result(id), into: w.staging.appending(path: previewID.uuidString), id: previewID)
    }

    // MARK: Preview

    @Test func aPreviewIsTheCommitsFilesCheckedAgainstGitHub() async throws {
        let w = try world()
        let staged = try await stage(w, "nested")
        let p = staged.preview
        #expect(p.commit == m.commit)
        #expect(p.name == "nested")
        #expect(p.skillPath == "skills/nested/SKILL.md")
        #expect(p.canAdd)
        #expect(Set(p.files.map(\.path)) == ["SKILL.md", "scripts/lint.sh", "assets/logo.png", "references/x.md"])
        // Text from skills.sh, checked; the PNG it leaves out, from GitHub at the commit.
        #expect(p.files.first { $0.path == "SKILL.md" }?.via == "snapshot")
        #expect(p.files.first { $0.path == "assets/logo.png" }?.via == "raw")
        #expect(p.files.filter(\.runnable).map(\.path) == ["scripts/lint.sh"])
        let golden = try #require(try SkillHashesTests.golden().fixtures["nested"])
        #expect(p.treeSHA == golden.treeSHA)
        #expect(p.computedHash == golden.computedHash)
        #expect(try SkillHashes.treeSHA(folder: staged.folder) == golden.treeSHA)
        // Nothing anywhere but the staging folder.
        #expect(!FileManager.default.fileExists(atPath: w.home.appending(path: ".agents").path))
    }

    @Test func aTamperedSnapshotFileIsFetchedFromGitHubInstead() async throws {
        let w = try world()
        let body = #"{"files":[{"path":"SKILL.md","contents":"---\nname: nested\ndescription: evil\n---\n"}]}"#
        w.state.override("/api/download/\(m.owner)/\(m.repo)/nested", body: Data(body.utf8))
        let staged = try await stage(w, "nested")
        #expect(staged.preview.files.first { $0.path == "SKILL.md" }?.via == "raw")
        #expect(staged.preview.description == "A skill with a script, a binary and references.")
    }

    @Test func rateLimitedFallsBackToTheTarballAndGetsTheSameSkill() async throws {
        let w = try world()
        w.state.mode = .rateLimited
        let staged = try await stage(w, "nested")
        let golden = try #require(try SkillHashesTests.golden().fixtures["nested"])
        #expect(staged.preview.files.allSatisfy { $0.via == "tarball" })
        #expect(staged.preview.treeSHA == golden.treeSHA)
        #expect(staged.preview.computedHash == golden.computedHash)
    }

    @Test func aSkillThatIsNotThereSaysSo() async throws {
        let w = try world()
        let staged = try await stage(w, "missing")
        #expect(staged.preview.problems == [.notFoundInRepo])
        #expect(!staged.preview.canAdd)
    }

    @Test func anIDThatWouldSteerAPathIsRefused() async throws {
        let w = try world()
        await #expect(throws: DaemonAPI.CatalogError.self) { _ = try await stage(w, "..") }
    }

    @Test func pathsOutsideTheFolderAreUnsafe() {
        #expect(SkillPreviewer.isSafe("a/b.md"))
        #expect(!SkillPreviewer.isSafe("../b.md"))
        #expect(!SkillPreviewer.isSafe("/etc/passwd"))
        #expect(!SkillPreviewer.isSafe("a//b"))
    }

    @Test func frontMatterBlocksAndQuotesAreRead() {
        let text = "---\nname: \"my-skill\"\ndescription: >-\n  Line one\n  line two.\nother: x\n---\nbody"
        #expect(SkillFile(text: text) == SkillFile(text: text))
        #expect(SkillFile(text: text).name == "my-skill")
        #expect(SkillFile(text: text).description == "Line one line two.")
        #expect(SkillFile(text: "no front matter").name == nil)
        #expect(SkillFile.folderName("My Skill!") == "my-skill")
        #expect(SkillFile.slug("SwiftUI_Expert Skill") == "swiftui-expert-skill")
    }

    // MARK: Destinations

    @Test func destinationsResolve() throws {
        let w = try world()
        #expect(w.personal.skills == w.home.appending(path: ".agents/skills"))
        #expect(w.personal.trash == w.root.appending(path: "trash"))
        #expect(throws: DaemonAPI.CatalogError.noPersonalHome) {
            try SkillPlace.resolve(.personal, personalHome: nil, root: w.root, usesRealTrash: false, environment: [:],
                                   isProject: { _ in true })
        }
        let project = w.root.appending(path: "work")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let place = try SkillPlace.resolve(.project(folder: project.path), personalHome: nil, root: w.root,
                                           usesRealTrash: true, environment: [:], isProject: { $0 == project.standardizedFileURL })
        #expect(place.skills == project.standardizedFileURL.appending(path: ".agents/skills"))
        #expect(place.lock.lastPathComponent == "skills-lock.json")
        #expect(place.trash == nil)
        #expect(throws: DaemonAPI.CatalogError.notAProject(path: "/nowhere")) {
            try SkillPlace.resolve(.project(folder: "/nowhere"), personalHome: nil, root: w.root, usesRealTrash: false,
                                   environment: [:], isProject: { _ in true })
        }
    }

    // MARK: Add

    @Test func addingPutsExactlyThePreviewInPlaceAndRecordsIt() async throws {
        let w = try world()
        let staged = try await stage(w, "nested")
        #expect(w.installer.state(of: staged.preview, at: w.personal) == .free)
        let managed = try w.installer.add(staged, to: w.personal, replace: false)
        let target = w.home.appending(path: ".agents/skills/nested")
        let golden = try #require(try SkillHashesTests.golden().fixtures["nested"])
        #expect(try SkillHashes.treeSHA(folder: target) == golden.treeSHA)
        #expect(FileManager.default.isExecutableFile(atPath: target.appending(path: "scripts/lint.sh").path))
        let lock = try SkillLock.load(.personal, at: w.home.appending(path: ".agents/.skill-lock.json"))
        #expect(lock.entry("nested")?.source == "\(m.owner)/\(m.repo)")
        #expect(lock.entry("nested")?.skillFolderHash == golden.treeSHA)
        #expect(lock.entry("nested")?.sourceURL == "https://github.com/\(m.owner)/\(m.repo).git")
        #expect(CatalogSidecar.load(from: w.installer.sidecar).skills["personal/nested"]?.commit == m.commit)
        #expect(managed.source == "\(m.owner)/\(m.repo)")
        #expect(w.installer.state(of: staged.preview, at: w.personal) == .sameSkill(update: false))
        #expect(w.installer.managed(at: w.personal)["nested"]?.edited == false)
    }

    @Test func aFolderNoLockNamesIsNeverTouched() async throws {
        let w = try world()
        let mine = w.home.appending(path: ".agents/skills/nested")
        try FileManager.default.createDirectory(at: mine, withIntermediateDirectories: true)
        try "mine".write(to: mine.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        let staged = try await stage(w, "nested")
        #expect(w.installer.state(of: staged.preview, at: w.personal) == .unmanaged(path: mine.path))
        #expect(throws: DaemonAPI.CatalogError.unmanaged(path: mine.path)) {
            try w.installer.add(staged, to: w.personal, replace: true)
        }
        #expect(try String(contentsOf: mine.appending(path: "SKILL.md"), encoding: .utf8) == "mine")
    }

    @Test func aFailedLockWriteLeavesTheDestinationAsItWas() async throws {
        let w = try world()
        let staged = try await stage(w, "nested")
        struct Boom: Error {}
        let failing = SkillInstaller(sidecar: w.installer.sidecar, afterRename: { throw Boom() })
        #expect(throws: DaemonAPI.CatalogError.self) { try failing.add(staged, to: w.personal, replace: false) }
        #expect(!FileManager.default.fileExists(atPath: w.home.appending(path: ".agents/skills/nested").path))
        #expect((try? SkillLock.load(.personal, at: w.personal.lock).entry("nested")) == nil)
    }

    @Test func editingAnAddedSkillIsNoticed() async throws {
        let w = try world()
        _ = try w.installer.add(try await stage(w, "nested"), to: w.personal, replace: false)
        try "changed".write(to: w.home.appending(path: ".agents/skills/nested/SKILL.md"), atomically: true, encoding: .utf8)
        #expect(w.installer.managed(at: w.personal)["nested"]?.edited == true)
    }

    @Test func stagingKeepsEightAndSweepsOldOnes() async throws {
        let w = try world()
        let staging = SkillStaging(root: w.staging)
        let base = try await stage(w, "plain")
        let start = Date()
        for i in 0..<10 {
            var s = base
            s.preview.previewID = UUID()
            s.createdAt = start.addingTimeInterval(Double(i))
            await staging.put(s, now: start.addingTimeInterval(Double(i)))
        }
        // Ten put, eight kept: the two oldest, the first among them, are gone.
        #expect(await staging.get(base.preview.previewID, now: start) == nil)
        let later = start.addingTimeInterval(SkillStaging.lifetime + 20)
        var s = base
        s.preview.previewID = UUID()
        s.createdAt = start
        await staging.put(s, now: start)
        #expect(await staging.get(s.preview.previewID, now: later) == nil)
    }
}
#endif
