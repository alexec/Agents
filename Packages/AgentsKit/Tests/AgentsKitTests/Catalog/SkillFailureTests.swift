#if canImport(CryptoKit)
import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// When a skill can't just go in (059, tasks T050, frame E): a name another source already
/// has, a lock the app won't write, and an add stopped half way, whether by an error or by the
/// daemon dying.
@Suite("When a skill can't just go in")
struct SkillFailureTests {
    let m = CatalogStub.meta

    struct World {
        let root: URL
        let home: URL
        let previewer: SkillPreviewer
        let installer: SkillInstaller
        var personal: SkillPlace {
            try! SkillPlace.resolve(.personal, personalHome: home, root: root, usesRealTrash: false,
                                    environment: [:], isProject: { _ in false })
        }
    }

    func world() throws -> World {
        let root = URL(filePath: NSTemporaryDirectory()).appending(path: "catalog-fail-\(UUID().uuidString)")
        let home = root.appending(path: "home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let (session, _) = CatalogStub.make()
        return World(root: root, home: home,
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

    /// A lock entry for `nested` from a different repository, with a folder to match.
    func otherSourceHas(_ w: World) throws {
        let folder = w.personal.skills.appending(path: "nested")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "---\nname: nested\ndescription: Someone else's.\n---\n"
            .write(to: folder.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        var lock = try SkillLock.load(.personal, at: w.personal.lock)
        lock.upsert(name: "nested", source: "someone/else", skillPath: "SKILL.md", hash: "0000")
        try lock.write()
    }

    @Test func anotherSourcesSkillOfTheSameNameNeedsReplace() async throws {
        let w = try world()
        try otherSourceHas(w)
        let staged = try await stage(w, "nested")
        #expect(w.installer.state(of: staged.preview, at: w.personal) == .managedOther(source: "someone/else"))
        #expect(throws: DaemonAPI.CatalogError.replaceMismatch) { try w.installer.add(staged, to: w.personal, replace: false) }
        _ = try w.installer.add(staged, to: w.personal, replace: true)
        #expect(try SkillLock.load(.personal, at: w.personal.lock).entry("nested")?.source == "\(m.owner)/\(m.repo)")
    }

    @Test func aFailedReplaceBringsTheOldCopyBack() async throws {
        let w = try world()
        try otherSourceHas(w)
        struct Boom: Error {}
        let failing = SkillInstaller(sidecar: w.installer.sidecar, afterRename: { throw Boom() })
        let staged = try await stage(w, "nested")
        #expect(throws: DaemonAPI.CatalogError.self) { try failing.add(staged, to: w.personal, replace: true) }
        let text = try String(contentsOf: w.personal.skills.appending(path: "nested/SKILL.md"), encoding: .utf8)
        #expect(text.contains("Someone else's."))
        #expect(try SkillLock.load(.personal, at: w.personal.lock).entry("nested")?.source == "someone/else")
        #expect(!FileManager.default.fileExists(atPath: failing.journal.path))
    }

    /// The daemon dying between the rename and the lock write leaves a journal; the next
    /// start undoes the add, and the old copy is back (SC-003).
    @Test func aDaemonThatDiedMidAddIsUndoneAtTheNextStart() async throws {
        let w = try world()
        try otherSourceHas(w)
        let dying = SkillInstaller(sidecar: w.installer.sidecar, afterRename: { throw SkillInstaller.Stop() })
        let staged = try await stage(w, "nested")
        #expect(throws: DaemonAPI.CatalogError.self) { try dying.add(staged, to: w.personal, replace: true) }
        // As a killed daemon would leave it: the new folder in place, the lock not written.
        #expect(FileManager.default.fileExists(atPath: dying.journal.path))
        #expect(try String(contentsOf: w.personal.skills.appending(path: "nested/SKILL.md"), encoding: .utf8)
            .contains("A skill with a script"))

        #expect(SkillInstaller.recover(journal: dying.journal) != nil)
        let text = try String(contentsOf: w.personal.skills.appending(path: "nested/SKILL.md"), encoding: .utf8)
        #expect(text.contains("Someone else's."))
        #expect(try SkillLock.load(.personal, at: w.personal.lock).entry("nested")?.source == "someone/else")
        #expect(!FileManager.default.fileExists(atPath: dying.journal.path))
    }

    @Test func aDaemonThatDiedOnAFreshAddLeavesNoFolderBehind() async throws {
        let w = try world()
        let dying = SkillInstaller(sidecar: w.installer.sidecar, afterRename: { throw SkillInstaller.Stop() })
        let staged = try await stage(w, "plain")
        #expect(throws: DaemonAPI.CatalogError.self) { try dying.add(staged, to: w.personal, replace: false) }
        SkillInstaller.recover(journal: dying.journal)
        #expect(!FileManager.default.fileExists(atPath: w.personal.skills.appending(path: "plain").path))
        #expect((try? SkillLock.load(.personal, at: w.personal.lock).entry("plain")) == nil)
    }

    @Test func aFinishedAddIsLeftAloneByRecovery() async throws {
        let w = try world()
        _ = try w.installer.add(try await stage(w, "plain"), to: w.personal, replace: false)
        #expect(!FileManager.default.fileExists(atPath: w.installer.journal.path))
        #expect(SkillInstaller.recover(journal: w.installer.journal) == nil)
        #expect(FileManager.default.fileExists(atPath: w.personal.skills.appending(path: "plain/SKILL.md").path))
    }

    @Test func anUnreadableLockStopsTheAddBeforeAnythingMoves() async throws {
        let w = try world()
        try FileManager.default.createDirectory(at: w.personal.lock.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "{\"version\": 2, \"skills\": {}}".write(to: w.personal.lock, atomically: true, encoding: .utf8)
        let staged = try await stage(w, "plain")
        #expect(w.installer.state(of: staged.preview, at: w.personal) == .unavailable(.lockUnreadable(path: w.personal.lock.path)))
        #expect(throws: DaemonAPI.CatalogError.lockUnreadable(path: w.personal.lock.path)) {
            try w.installer.add(staged, to: w.personal, replace: false)
        }
        #expect(!FileManager.default.fileExists(atPath: w.personal.skills.appending(path: "plain").path))
        #expect(FileManager.default.fileExists(atPath: staged.folder.path))
    }

}
#endif
