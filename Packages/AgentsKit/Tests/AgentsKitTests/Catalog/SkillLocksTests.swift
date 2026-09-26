#if canImport(CryptoKit)
import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// The `skills` CLI's lock files, written as the CLI writes them (059, tasks T008). The
/// expected files were made by the CLI's own write logic under `node`
/// (`specs/059-marketplace/walk/golden-locks.mjs`), not by the code under test.
@Suite("Skill lock files")
struct SkillLocksTests {
    static let locks = SkillHashesTests.fixtures.appending(path: "locks")
    static let now = try! Date("2026-09-26T15:10:00.000Z", strategy: .iso8601.year().month().day()
        .time(includingFractionalSeconds: true).timeZone(separator: .omitted))

    func scratch() throws -> URL {
        let dir = URL(filePath: NSTemporaryDirectory()).appending(path: "SkillLocks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func copy(_ name: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: Self.locks.appending(path: name), to: url)
    }

    @Test func personalComesOutAsTheCLIWritesIt() throws {
        let url = try scratch().appending(path: ".agents/.skill-lock.json")
        try copy("personal-before.json", to: url)
        var lock = try SkillLock.load(.personal, at: url)
        lock.upsert(name: "nested", source: "fixture-owner/fixture-skills", skillPath: "skills/nested/SKILL.md",
                    hash: "b4146b99df32f406302cf36ff69949f3b394ea01", now: Self.now)
        lock.upsert(name: "find-skills", source: "vercel-labs/skills", skillPath: "skills/find-skills/SKILL.md",
                    hash: "1111111111111111111111111111111111111111", now: Self.now)
        try lock.write()
        let want = try String(contentsOf: Self.locks.appending(path: "personal-after.json"), encoding: .utf8)
        let got = try String(contentsOf: url, encoding: .utf8)
        #expect(got == want)
        #expect(!got.hasSuffix("\n"))
        // Replacing kept the first install time and moved the update time on.
        #expect(lock.entry("find-skills")?.installedAt == "2026-09-17T14:59:25.092Z")
        #expect(lock.entry("find-skills")?.updatedAt == "2026-09-26T15:10:00.000Z")
    }

    @Test func projectComesOutAsTheCLIWritesIt() throws {
        let url = try scratch().appending(path: "skills-lock.json")
        try copy("project-before.json", to: url)
        var lock = try SkillLock.load(.project, at: url)
        lock.upsert(name: "nested", source: "fixture-owner/fixture-skills", skillPath: "skills/nested/SKILL.md",
                    hash: "43d79cc2b2a7065d4f3f4cc5ae35447d31c5b22469dcee4c35395c2c09d0ac0e", now: Self.now)
        try lock.write()
        let want = try String(contentsOf: Self.locks.appending(path: "project-after.json"), encoding: .utf8)
        #expect(try String(contentsOf: url, encoding: .utf8) == want)
    }

    @Test func aNewPersonalLockStartsAsTheCLIsEmptyOne() throws {
        let url = try scratch().appending(path: ".agents/.skill-lock.json")
        var lock = try SkillLock.load(.personal, at: url)
        lock.upsert(name: "plain", source: "o/r", skillPath: "skills/plain/SKILL.md", hash: "aa", now: Self.now)
        try lock.write()
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.hasPrefix("{\n  \"version\": 3,\n  \"skills\": {\n    \"plain\": {"))
        #expect(text.hasSuffix("\n  },\n  \"dismissed\": {}\n}"))
    }

    @Test func removingLeavesEverythingElse() throws {
        let url = try scratch().appending(path: ".agents/.skill-lock.json")
        try copy("personal-before.json", to: url)
        var lock = try SkillLock.load(.personal, at: url)
        lock.remove(name: "find-skills")
        try lock.write()
        let again = try SkillLock.load(.personal, at: url)
        #expect(again.names == ["zapier-thing"])
        #expect(again.root["lastSelectedAgents"] == .array([.string("claude-code"), .string("codex")]))
    }

    @Test(arguments: ["{\"version\": 2, \"skills\": {}}", "{not json", "{\"version\": 3}"])
    func anUnreadableLockIsRefusedAndLeftAlone(_ text: String) throws {
        let url = try scratch().appending(path: ".agents/.skill-lock.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        #expect(throws: DaemonAPI.CatalogError.lockUnreadable(path: url.path)) { try SkillLock.load(.personal, at: url) }
        #expect(try String(contentsOf: url, encoding: .utf8) == text)
    }

    @Test func xdgStateHomeMovesThePersonalLock() {
        let home = URL(filePath: "/tmp/h")
        #expect(SkillLock.personalURL(home: home, environment: [:]).path == "/tmp/h/.agents/.skill-lock.json")
        #expect(SkillLock.personalURL(home: home, environment: ["XDG_STATE_HOME": "/tmp/state"]).path
                == "/tmp/state/skills/.skill-lock.json")
    }

    @Test(arguments: [("1.50", "1.5"), ("1e3", "1000"), ("-0", "0"), ("1e-7", "1e-7"), ("1.5e30", "1.5e+30"), ("42", "42")])
    func numbersAreWrittenAsJavaScriptWritesThem(_ pair: (String, String)) {
        #expect(OrderedJSON.javaScriptNumber(pair.0) == pair.1)
    }
}

@Suite("The catalogue's sidecar")
struct CatalogSidecarTests {
    @Test func keysNameTheDestinationAndTheSkill() {
        #expect(CatalogSidecar.key(.personal, name: "x") == "personal/x")
        #expect(CatalogSidecar.key(.project(folder: "/tmp/p/"), name: "x") == "/tmp/p/x")
    }

    @Test func aMissingFileIsEmptyAndAnEntryWithNoLockIsDropped() throws {
        let url = URL(filePath: NSTemporaryDirectory()).appending(path: "sidecar-\(UUID().uuidString).json")
        var sidecar = CatalogSidecar.load(from: url)
        #expect(sidecar.skills.isEmpty)
        let record = CatalogSidecar.Record(commit: "c", committedAt: nil, treeSHA: "t", catalogue: "skills.sh", addedAt: Date())
        sidecar.skills["personal/kept"] = record
        sidecar.skills["personal/gone"] = record
        try sidecar.save(to: url) { $0 == "personal/kept" }
        #expect(Array(CatalogSidecar.load(from: url).skills.keys) == ["personal/kept"])
    }
}
#endif
