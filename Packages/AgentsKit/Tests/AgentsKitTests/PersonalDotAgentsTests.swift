import Foundation
import Testing
@testable import AgentsKit

/// The person's `~/.agents` reaches every runtime (054), on a home made for each test.
/// None of these reads `$HOME` (SC-006): the home is always passed in.
@Suite("Personal ~/.agents", .timeLimit(.minutes(1)))
struct PersonalDotAgentsTests {
    private let fileManager = FileManager.default
    private let everyRuntime: Set<String> = ["claude", "codex", "grok", "cursor", "copilot", "gemini"]

    private func home() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("PersonalDotAgentsTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url.resolvingSymlinksInPath()
    }

    private func write(_ home: URL, _ path: String, _ contents: String) throws {
        let url = home.appending(path: path)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    private func skill(_ home: URL, _ name: String) throws {
        try write(home, ".agents/skills/\(name)/SKILL.md", "---\nname: \(name)\ndescription: A skill.\n---\n")
    }

    private func link(_ home: URL, _ path: String) -> String? {
        try? fileManager.destinationOfSymbolicLink(atPath: home.appending(path: path).path)
    }

    private func reconcile(_ home: URL, installed: Set<String>? = nil,
                           record: inout PersonalDotAgents.Record) {
        PersonalDotAgents.reconcile(home: home, installed: installed ?? everyRuntime, record: &record)
    }

    // US1 scenario 1, FR-002, FR-013
    @Test func aSharedSkillIsLinkedForClaudeRelatively() throws {
        let home = try home()
        try skill(home, "grill-me")
        var record = PersonalDotAgents.Record(home: home.path)

        reconcile(home, record: &record)

        #expect(link(home, ".claude/skills/grill-me") == "../../.agents/skills/grill-me")
        let seen = try String(contentsOf: home.appending(path: ".claude/skills/grill-me/SKILL.md"), encoding: .utf8)
        #expect(seen.contains("name: grill-me"))
        #expect(record.links[".claude/skills/grill-me"] == "../../.agents/skills/grill-me")
    }

    // FR-001
    @Test func theSharedFoldersAreMadeWhenMissing() throws {
        let home = try home()
        var record = PersonalDotAgents.Record(home: home.path)

        reconcile(home, record: &record)

        #expect(DotAgents.isDirectory(home.appending(path: ".agents/skills")))
        #expect(DotAgents.isDirectory(home.appending(path: ".agents/personas")))
    }

    // US1 scenario 2, FR-007
    @Test func claudeAISyncedSkillsAreNeverTouched() throws {
        let home = try home()
        try write(home, ".claude/skills/synced/.bucket-abc", "")
        try write(home, ".claude/skills/synced/house/SKILL.md", "synced body")
        try skill(home, "synced")
        let before = try snapshot(home.appending(path: ".claude/skills/synced"))
        var record = PersonalDotAgents.Record(home: home.path)

        reconcile(home, record: &record)

        #expect(try snapshot(home.appending(path: ".claude/skills/synced")) == before)
        #expect(link(home, ".claude/skills/synced") == nil)
    }

    @Test func aSkillFolderMarkedByASyncIsLeftAlone() throws {
        let home = try home()
        try skill(home, "mirrored")
        try write(home, ".claude/skills/mirrored/.sync-manifest.json", "{}")
        var record = PersonalDotAgents.Record(home: home.path)

        reconcile(home, record: &record)

        #expect(link(home, ".claude/skills/mirrored") == nil)
        #expect(record.links.isEmpty)
    }

    // US1 scenario 4
    @Test func runtimesThatReadTheSharedFolderGetNoSkillLinks() throws {
        let home = try home()
        try skill(home, "grill-me")
        for folder in [".codex", ".grok", ".cursor", ".copilot"] {
            try fileManager.createDirectory(at: home.appending(path: folder), withIntermediateDirectories: true)
        }
        var record = PersonalDotAgents.Record(home: home.path)

        reconcile(home, record: &record)

        for folder in [".codex", ".grok", ".cursor", ".copilot"] {
            #expect(!DotAgents.exists(home.appending(path: "\(folder)/skills/grill-me")))
        }
        #expect(record.links.keys.allSatisfy { $0.hasPrefix(".claude/") })
    }

    @Test func aRuntimeThatIsNotInstalledGetsNothing() throws {
        let home = try home()
        try skill(home, "grill-me")
        var record = PersonalDotAgents.Record(home: home.path)

        reconcile(home, installed: ["codex"], record: &record)

        #expect(!DotAgents.exists(home.appending(path: ".claude")))
        #expect(record.links.isEmpty)
    }

    // spec, Edge Cases
    @Test func aSkillsFolderThatIsItselfALinkIsLeftAlone() throws {
        let home = try home()
        try skill(home, "grill-me")
        let elsewhere = home.appending(path: "dotfiles/claude-skills")
        try fileManager.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: home.appending(path: ".claude"), withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(atPath: home.appending(path: ".claude/skills").path,
                                           withDestinationPath: "../dotfiles/claude-skills")
        var record = PersonalDotAgents.Record(home: home.path)

        reconcile(home, record: &record)

        #expect((try fileManager.contentsOfDirectory(atPath: elsewhere.path)).isEmpty)
    }

    @Test func aRealSkillOfTheSameNameIsAClashAndLeftAlone() throws {
        let home = try home()
        try skill(home, "review")
        try write(home, ".claude/skills/review/SKILL.md", "Claude's own")
        var record = PersonalDotAgents.Record(home: home.path)

        reconcile(home, record: &record)

        #expect(link(home, ".claude/skills/review") == nil)
        #expect(try String(contentsOf: home.appending(path: ".claude/skills/review/SKILL.md"), encoding: .utf8) == "Claude's own")
    }

    @Test func aLinkAnotherInstallerMadeIsKeptAndCounted() throws {
        let home = try home()
        try skill(home, "grill-me")
        try fileManager.createDirectory(at: home.appending(path: ".claude/skills"), withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(atPath: home.appending(path: ".claude/skills/grill-me").path,
                                           withDestinationPath: home.appending(path: ".agents/skills/grill-me").path)
        var record = PersonalDotAgents.Record(home: home.path)

        reconcile(home, record: &record)

        #expect(link(home, ".claude/skills/grill-me") == home.appending(path: ".agents/skills/grill-me").path)
        #expect(record.links[".claude/skills/grill-me"] != nil)
    }

    // FR-011, SC-004
    @Test func reconcilingTwiceChangesNothingTheSecondTime() throws {
        let home = try home()
        try skill(home, "grill-me")
        try skill(home, "review")
        var record = PersonalDotAgents.Record(home: home.path)
        reconcile(home, record: &record)
        let before = try snapshot(home)
        let recorded = record

        reconcile(home, record: &record)

        #expect(try snapshot(home) == before)
        #expect(record == recorded)
    }

    @Test func theRecordIsForOneHomeOnly() throws {
        let home = try home()
        let file = home.appending(path: "personal-layout.json")
        var record = PersonalDotAgents.Record(home: "/Users/someone-else")
        record.links["x"] = "y"
        try record.save(to: file)

        #expect(PersonalDotAgents.Record.load(from: file, home: home).links.isEmpty)
        #expect(PersonalDotAgents.Record.load(from: home.appending(path: "missing.json"), home: home).home == home.path)
    }

    // SC-005. A wall-clock budget, so quarantined in CI like the others; the best of
    // three, so one scheduling hiccup on a loaded Mac is not a failure.
    @Test(.flakyUnderLoad) func a100SkillReconcileIsQuick() throws {
        let home = try home()
        for index in 0..<100 { try skill(home, "skill-\(index)") }
        var record = PersonalDotAgents.Record(home: home.path)
        reconcile(home, record: &record)

        let clock = ContinuousClock()
        let took = (0..<3).map { _ in clock.measure { reconcile(home, record: &record) } }.min()!

        #expect(took < .milliseconds(50))
    }

    /// Every entry under a folder, with what a link points at or a file holds, and each
    /// entry's modification date, so "nothing changed" means exactly that.
    private func snapshot(_ root: URL) throws -> [String: String] {
        var result: [String: String] = [:]
        let enumerator = fileManager.enumerator(atPath: root.path)
        while let path = enumerator?.nextObject() as? String {
            let url = root.appending(path: path)
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            if let destination = try? fileManager.destinationOfSymbolicLink(atPath: url.path) {
                result[path] = "link \(destination) \(modified)"
            } else if DotAgents.isDirectory(url) {
                result[path] = "folder \(modified)"
            } else {
                result[path] = "file \((try? String(contentsOf: url, encoding: .utf8)) ?? "") \(modified)"
            }
        }
        return result
    }
}
