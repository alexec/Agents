#if canImport(CryptoKit)
import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// Whether an added skill's source has moved on, what updating would change, and taking a
/// skill out (059, tasks T044, T045). The stand-in's second commit changes `nested` (one line
/// in SKILL.md, one new file) and leaves `plain` as it was.
@Suite("Updating and removing a skill")
struct SkillUpdateRemoveTests {
    let m = CatalogStub.meta

    struct World {
        let root: URL
        let home: URL
        let state: CatalogStub.State
        let previewer: SkillPreviewer
        let installer: SkillInstaller
        let updates: SkillUpdates
        var personal: SkillPlace {
            try! SkillPlace.resolve(.personal, personalHome: home, root: root, usesRealTrash: false,
                                    environment: [:], isProject: { _ in false })
        }
    }

    func world() throws -> World {
        let root = URL(filePath: NSTemporaryDirectory()).appending(path: "catalog-update-\(UUID().uuidString)")
        let home = root.appending(path: "home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let (session, state) = CatalogStub.make()
        let github = GitHubSource(session: session, endpoints: CatalogStub.endpoints, gh: nil)
        let sidecar = root.appending(path: "catalog-skills.json")
        return World(root: root, home: home, state: state,
                     previewer: SkillPreviewer(catalog: SkillsCatalog(session: session, endpoints: CatalogStub.endpoints),
                                               github: github),
                     installer: SkillInstaller(sidecar: sidecar), updates: SkillUpdates(github: github, sidecar: sidecar))
    }

    func stage(_ w: World, _ id: String) async throws -> StagedSkill {
        let previewID = UUID()
        let result = DaemonAPI.CatalogResult(id: "\(m.owner)/\(m.repo)/\(id)", name: id, owner: m.owner, repo: m.repo,
                                             skillID: id, installs: 1, known: false)
        return try await w.previewer.stage(result, into: w.root.appending(path: "staging/\(previewID)"), id: previewID)
    }

    func addBoth(_ w: World) async throws {
        _ = try w.installer.add(try await stage(w, "nested"), to: w.personal, replace: false)
        _ = try w.installer.add(try await stage(w, "plain"), to: w.personal, replace: false)
    }

    func treeRequests(_ w: World) -> Int { w.state.requests.filter { $0.path.contains("/git/trees/") }.count }

    // MARK: The check

    @Test func anUnmovedHeadIsCurrentAndCostsNoTreeRequest() async throws {
        let w = try world()
        try await addBoth(w)
        let before = treeRequests(w)
        var cache: [String: SkillUpdates.Answer] = [:]
        let states = await w.updates.check(w.installer.managed(at: w.personal), at: w.personal, cache: &cache)
        #expect(states == ["nested": .current, "plain": .current])
        #expect(treeRequests(w) == before)
    }

    @Test func aChangedFolderIsAvailableAndAnUnchangedOneMovesForward() async throws {
        let w = try world()
        try await addBoth(w)
        w.state.mode = .movedOn
        var cache: [String: SkillUpdates.Answer] = [:]
        let states = await w.updates.check(w.installer.managed(at: w.personal), at: w.personal, cache: &cache)
        #expect(states["nested"] == .available(commit: m.next))
        #expect(states["plain"] == .current)
        // plain's record moved to the new commit, so the next check needs no request for it.
        #expect(CatalogSidecar.load(from: w.installer.sidecar).skills["personal/plain"]?.commit == m.next)
        #expect(CatalogSidecar.load(from: w.installer.sidecar).skills["personal/nested"]?.commit == m.commit)
    }

    @Test func aSecondCheckWithinTheHourAsksNothing() async throws {
        let w = try world()
        try await addBoth(w)
        w.state.mode = .movedOn
        var cache: [String: SkillUpdates.Answer] = [:]
        _ = await w.updates.check(w.installer.managed(at: w.personal), at: w.personal, cache: &cache)
        let asked = w.state.requests.count
        let again = await w.updates.check(w.installer.managed(at: w.personal), at: w.personal, cache: &cache)
        #expect(again["nested"] == .available(commit: m.next))
        #expect(w.state.requests.count == asked)
    }

    // MARK: Update

    @Test func updatingShowsWhatChangesThenReplacesKeepingTheInstallTime() async throws {
        let w = try world()
        try await addBoth(w)
        let installedAt = try SkillLock.load(.personal, at: w.personal.lock).entry("nested")?.installedAt
        w.state.mode = .movedOn
        let fresh = try await stage(w, "nested")
        #expect(fresh.preview.commit == m.next)
        #expect(w.installer.state(of: fresh.preview, at: w.personal) == .sameSkill(update: true))
        let changes = SkillInstaller.changes(from: w.personal.skills.appending(path: "nested"), to: fresh.folder)
        #expect(changes == .init(added: ["references/y.md"], changed: ["SKILL.md"], removed: []))
        #expect(throws: DaemonAPI.CatalogError.replaceMismatch) { try w.installer.add(fresh, to: w.personal, replace: false) }
        _ = try w.installer.add(fresh, to: w.personal, replace: true, now: Date().addingTimeInterval(60))
        let entry = try SkillLock.load(.personal, at: w.personal.lock).entry("nested")
        #expect(entry?.installedAt == installedAt)
        #expect(entry?.updatedAt != installedAt)
        #expect(entry?.skillFolderHash == fresh.preview.treeSHA)
        #expect(FileManager.default.fileExists(atPath: w.personal.skills.appending(path: "nested/references/y.md").path))
        // The old copy went to this root's own Trash, never the person's.
        #expect(try FileManager.default.contentsOfDirectory(atPath: w.root.appending(path: "trash").path)
            .contains { $0.hasPrefix("nested-") })
    }

    @Test func anEditedSkillSaysSoBeforeAnUpdate() async throws {
        let w = try world()
        try await addBoth(w)
        try "mine now".write(to: w.personal.skills.appending(path: "nested/SKILL.md"), atomically: true, encoding: .utf8)
        #expect(w.installer.managed(at: w.personal)["nested"]?.edited == true)
        #expect(w.installer.managed(at: w.personal)["plain"]?.edited == false)
    }

    // MARK: Remove

    @Test func removingTrashesTheFolderAndDropsItsRecords() async throws {
        let w = try world()
        try await addBoth(w)
        let trashed = try w.installer.remove("nested", at: w.personal)
        #expect(!FileManager.default.fileExists(atPath: w.personal.skills.appending(path: "nested").path))
        #expect(trashed.path.hasPrefix(w.root.appending(path: "trash").path))
        #expect(FileManager.default.fileExists(atPath: trashed.appending(path: "SKILL.md").path))
        let lock = try SkillLock.load(.personal, at: w.personal.lock)
        #expect(lock.entry("nested") == nil)
        #expect(lock.entry("plain") != nil)
        #expect(CatalogSidecar.load(from: w.installer.sidecar).skills["personal/nested"] == nil)
    }

    @Test func aSkillNoLockNamesIsNeverRemoved() async throws {
        let w = try world()
        let mine = w.personal.skills.appending(path: "mine")
        try FileManager.default.createDirectory(at: mine, withIntermediateDirectories: true)
        try "---\nname: mine\ndescription: Mine.\n---\n".write(to: mine.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        #expect(throws: DaemonAPI.CatalogError.notManaged(name: "mine")) { _ = try w.installer.remove("mine", at: w.personal) }
        #expect(FileManager.default.fileExists(atPath: mine.appending(path: "SKILL.md").path))
    }
}
#endif
