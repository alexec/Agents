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
        #expect(record.links[".claude/skills/mirrored"] == nil)
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
        #expect(record.links.keys.filter { $0.contains("/skills/") }.allSatisfy { $0.hasPrefix(".claude/") })
    }

    @Test func aRuntimeThatIsNotInstalledGetsNothing() throws {
        let home = try home()
        try skill(home, "grill-me")
        var record = PersonalDotAgents.Record(home: home.path)

        reconcile(home, installed: ["codex"], record: &record)

        #expect(!DotAgents.exists(home.appending(path: ".claude")))
        #expect(record.links.keys.allSatisfy { !$0.hasPrefix(".claude/") })
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

    // SC-005. A wall-clock budget, held only by the perf check; the best of three, so
    // one scheduling hiccup is not a failure.
    @Test(.perfBudget) func a100SkillReconcileIsQuick() throws {
        let home = try home()
        for index in 0..<100 { try skill(home, "skill-\(index)") }
        var record = PersonalDotAgents.Record(home: home.path)
        reconcile(home, record: &record)

        let clock = ContinuousClock()
        let took = (0..<3).map { _ in clock.measure { reconcile(home, record: &record) } }.min()!

        PerfBudget.expect(took, under: .milliseconds(50), "reconciling 100 skills")
    }

    // MARK: - US2: instructions

    private func read(_ home: URL, _ path: String) throws -> String {
        try String(contentsOf: home.appending(path: path), encoding: .utf8)
    }

    // US2 scenarios 1 and 2, FR-003, FR-013
    @Test func everyRuntimeWithAnInstructionsFileIsLinkedToAgentsMD() throws {
        let home = try home()
        try write(home, ".agents/AGENTS.md", "OSPREY-3\n")
        var record = PersonalDotAgents.Record(home: home.path)

        reconcile(home, record: &record)

        #expect(link(home, ".claude/CLAUDE.md") == "../.agents/AGENTS.md")
        #expect(link(home, ".codex/AGENTS.md") == "../.agents/AGENTS.md")
        #expect(link(home, ".grok/AGENTS.md") == "../.agents/AGENTS.md")
        #expect(link(home, ".copilot/copilot-instructions.md") == "../.agents/AGENTS.md")
        #expect(try read(home, ".copilot/copilot-instructions.md") == "OSPREY-3\n")
        #expect(!DotAgents.exists(home.appending(path: ".cursor")))
        #expect(record.links[".codex/AGENTS.md"] == "../.agents/AGENTS.md")
    }

    // US2 scenario 3
    @Test func withNoInstructionsAnywhereAShortAgentsMDIsWritten() throws {
        let home = try home()
        var record = PersonalDotAgents.Record(home: home.path)

        reconcile(home, record: &record)

        let written = try read(home, ".agents/AGENTS.md")
        #expect(written.contains("every agent"))
        #expect(written.count < 600)
        #expect(link(home, ".claude/CLAUDE.md") == "../.agents/AGENTS.md")
    }

    @Test func instructionsGoOnlyToInstalledRuntimes() throws {
        let home = try home()
        try write(home, ".agents/AGENTS.md", "mine")
        var record = PersonalDotAgents.Record(home: home.path)

        reconcile(home, installed: ["codex"], record: &record)

        #expect(link(home, ".codex/AGENTS.md") == "../.agents/AGENTS.md")
        #expect(!DotAgents.exists(home.appending(path: ".claude")))
        #expect(!DotAgents.exists(home.appending(path: ".copilot")))
    }

    // MARK: - US3: what is already there moves in

    /// What a folder holds, byte for byte.
    private func contents(_ folder: URL) throws -> [String: Data] {
        var result: [String: Data] = [:]
        let enumerator = fileManager.enumerator(atPath: folder.path)
        while let path = enumerator?.nextObject() as? String {
            let url = folder.appending(path: path)
            if !DotAgents.isDirectory(url) { result[path] = try Data(contentsOf: url) }
        }
        return result
    }

    // US3 scenario 1, FR-005
    @Test func aRealClaudeSkillMovesInAndIsLinkedBack() throws {
        let home = try home()
        try write(home, ".claude/skills/mine/SKILL.md", "---\nname: mine\n---\nbody")
        try write(home, ".claude/skills/mine/scripts/run.sh", "#!/bin/sh\necho hi\n")
        let before = try contents(home.appending(path: ".claude/skills/mine"))
        var record = PersonalDotAgents.Record(home: home.path)

        reconcile(home, record: &record)

        #expect(link(home, ".claude/skills/mine") == "../../.agents/skills/mine")
        #expect(try contents(home.appending(path: ".agents/skills/mine")) == before)
        #expect(try contents(home.appending(path: ".claude/skills/mine")) == before)  // through the link
    }

    // US3 scenario 2
    @Test func aClaudeSkillWhoseNameIsTakenStaysWhereItIs() throws {
        let home = try home()
        try write(home, ".claude/skills/review/SKILL.md", "Claude's")
        try write(home, ".agents/skills/review/SKILL.md", "shared")
        var record = PersonalDotAgents.Record(home: home.path)

        reconcile(home, record: &record)

        #expect(link(home, ".claude/skills/review") == nil)
        #expect(try read(home, ".claude/skills/review/SKILL.md") == "Claude's")
        #expect(try read(home, ".agents/skills/review/SKILL.md") == "shared")
    }

    @Test func managedAndHiddenClaudeFoldersAreNotAdopted() throws {
        let home = try home()
        try write(home, ".claude/skills/synced/house/SKILL.md", "synced")
        try write(home, ".claude/skills/mirrored/.bucket-1", "")
        try write(home, ".claude/skills/.cache/x", "")
        var record = PersonalDotAgents.Record(home: home.path)

        reconcile(home, record: &record)

        for name in ["synced", "mirrored", ".cache"] {
            #expect(DotAgents.isDirectory(home.appending(path: ".claude/skills/\(name)")))
            #expect(link(home, ".claude/skills/\(name)") == nil)
            #expect(!DotAgents.exists(home.appending(path: ".agents/skills/\(name)")))
        }
    }

    // US3 scenario 3, FR-006
    @Test func aRealClaudeMDMovesInAndIsLinkedBack() throws {
        let home = try home()
        try write(home, ".claude/CLAUDE.md", "KITE-1\n")
        var record = PersonalDotAgents.Record(home: home.path)

        reconcile(home, record: &record)

        #expect(try read(home, ".agents/AGENTS.md") == "KITE-1\n")
        #expect(link(home, ".claude/CLAUDE.md") == "../.agents/AGENTS.md")
        #expect(link(home, ".codex/AGENTS.md") == "../.agents/AGENTS.md")
    }

    // US3 scenario 4
    @Test func aRealClaudeMDBesideARealAgentsMDStaysWhereItIs() throws {
        let home = try home()
        try write(home, ".claude/CLAUDE.md", "Claude's")
        try write(home, ".agents/AGENTS.md", "shared")
        var record = PersonalDotAgents.Record(home: home.path)

        reconcile(home, record: &record)

        #expect(link(home, ".claude/CLAUDE.md") == nil)
        #expect(try read(home, ".claude/CLAUDE.md") == "Claude's")
        #expect(try read(home, ".agents/AGENTS.md") == "shared")
    }

    // FR-006: only the first found moves, in the order Claude, Codex, Copilot, Grok
    @Test func onlyTheFirstRealInstructionsFileMoves() throws {
        let home = try home()
        try write(home, ".codex/AGENTS.md", "codex's")
        try write(home, ".grok/AGENTS.md", "grok's")
        var record = PersonalDotAgents.Record(home: home.path)

        reconcile(home, record: &record)

        #expect(try read(home, ".agents/AGENTS.md") == "codex's")
        #expect(link(home, ".codex/AGENTS.md") == "../.agents/AGENTS.md")
        #expect(link(home, ".grok/AGENTS.md") == nil)
        #expect(try read(home, ".grok/AGENTS.md") == "grok's")
    }

    // MARK: - US4: out of the way

    // US4 scenario 2, FR-009
    @Test func aLinkThePersonDeletedIsNotPutBack() throws {
        let home = try home()
        try skill(home, "grill-me")
        try write(home, ".agents/AGENTS.md", "mine")
        var record = PersonalDotAgents.Record(home: home.path)
        reconcile(home, record: &record)
        try fileManager.removeItem(at: home.appending(path: ".claude/skills/grill-me"))
        try fileManager.removeItem(at: home.appending(path: ".codex/AGENTS.md"))

        reconcile(home, record: &record)

        #expect(!DotAgents.exists(home.appending(path: ".claude/skills/grill-me")))
        #expect(!DotAgents.exists(home.appending(path: ".codex/AGENTS.md")))
    }

    // US4 scenario 3, FR-008
    @Test func aRemovedSkillsDanglingLinksGoAndNoOthers() throws {
        let home = try home()
        try skill(home, "grill-me")
        try skill(home, "review")
        var record = PersonalDotAgents.Record(home: home.path)
        reconcile(home, record: &record)
        // The installer's own absolute link, a link of the person's to elsewhere that
        // points at nothing, and a skill that goes.
        let skills = home.appending(path: ".claude/skills")
        try skill(home, "installed")
        try fileManager.createSymbolicLink(atPath: skills.appending(path: "installed").path,
                                           withDestinationPath: home.appending(path: ".agents/skills/installed").path)
        try fileManager.createSymbolicLink(atPath: skills.appending(path: "elsewhere").path,
                                           withDestinationPath: "/nowhere/at/all")
        try fileManager.removeItem(at: home.appending(path: ".agents/skills/grill-me"))
        try fileManager.removeItem(at: home.appending(path: ".agents/skills/installed"))

        reconcile(home, record: &record)

        #expect(link(home, ".claude/skills/grill-me") == nil)
        #expect(link(home, ".claude/skills/installed") == nil)
        #expect(link(home, ".claude/skills/elsewhere") == "/nowhere/at/all")
        #expect(link(home, ".claude/skills/review") == "../../.agents/skills/review")
        #expect(record.links[".claude/skills/grill-me"] == nil)
    }

    // The record entry goes with the skill, so the same skill added again is linked again.
    @Test func aSkillAddedAgainIsLinkedAgain() throws {
        let home = try home()
        try skill(home, "grill-me")
        var record = PersonalDotAgents.Record(home: home.path)
        reconcile(home, record: &record)
        try fileManager.removeItem(at: home.appending(path: ".agents/skills/grill-me"))
        reconcile(home, record: &record)

        try skill(home, "grill-me")
        reconcile(home, record: &record)

        #expect(link(home, ".claude/skills/grill-me") == "../../.agents/skills/grill-me")
    }

    // US4 scenario 4 with everything at once: adopted, linked, clashing, managed.
    @Test func aBusyHomeReconciledTwiceChangesNothingTheSecondTime() throws {
        let home = try home()
        try skill(home, "grill-me")
        try write(home, ".claude/skills/mine/SKILL.md", "mine")
        try write(home, ".claude/skills/review/SKILL.md", "Claude's")
        try skill(home, "review")
        try write(home, ".claude/skills/synced/.bucket-1", "")
        try write(home, ".claude/CLAUDE.md", "KITE-1")
        var record = PersonalDotAgents.Record(home: home.path)
        reconcile(home, record: &record)
        let before = try snapshot(home)
        let recorded = record

        reconcile(home, record: &record)

        #expect(try snapshot(home) == before)
        #expect(record == recorded)
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
