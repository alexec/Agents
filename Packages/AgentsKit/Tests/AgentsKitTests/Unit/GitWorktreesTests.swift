import Foundation
import Testing
@testable import AgentsKit

/// Reading `git worktree list --porcelain` (030).
@Suite("What git says about a repository's worktrees")
struct GitWorktreesTests {
    @Test func everyKindOfEntryIsRead() {
        let porcelain = """
            worktree /repo
            HEAD 1111111111111111111111111111111111111111
            branch refs/heads/main

            worktree /repo/.agents/worktrees/fix-login
            HEAD 2222222222222222222222222222222222222222
            branch refs/heads/agents/fix-login

            worktree /elsewhere/detached
            HEAD 3333333333333333333333333333333333333333
            detached

            worktree /repo/.agents/worktrees/held
            HEAD 4444444444444444444444444444444444444444
            branch refs/heads/agents/held
            locked because I said so

            worktree /repo/.agents/worktrees/gone
            HEAD 5555555555555555555555555555555555555555
            branch refs/heads/agents/gone
            prunable gitdir file points to non-existent location

            """
        let entries = GitWorktrees.parse(porcelain)
        #expect(entries.map(\.path.path) == ["/repo", "/repo/.agents/worktrees/fix-login", "/elsewhere/detached",
                                             "/repo/.agents/worktrees/held", "/repo/.agents/worktrees/gone"])
        #expect(entries.map(\.branch) == ["main", "agents/fix-login", nil, "agents/held", "agents/gone"])
        #expect(entries[0].head == "1111111111111111111111111111111111111111")
        #expect(entries.map(\.isLocked) == [false, false, false, true, false])
        #expect(entries.map(\.isPrunable) == [false, false, false, false, true])
    }

    @Test func aListWithoutATrailingBlankLineKeepsItsLastEntry() {
        let entries = GitWorktrees.parse("worktree /repo\nHEAD abc\nbranch refs/heads/main")
        #expect(entries.count == 1)
        #expect(entries[0].branch == "main")
    }

    @Test func aBareRepositoryIsMarked() {
        let entries = GitWorktrees.parse("worktree /repo.git\nbare\n")
        #expect(entries.first?.isBare == true)
    }

    @Test func theExcludeLineIsAddedOnceAndLeavesWhatWasThere() throws {
        let common = FileManager.default.temporaryDirectory.appending(path: "gw-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: common) }
        let info = common.appending(path: "info")
        try FileManager.default.createDirectory(at: info, withIntermediateDirectories: true)
        try "*.log".write(to: info.appending(path: "exclude"), atomically: true, encoding: .utf8)

        try GitWorktrees.ensureExcluded(commonDir: common)
        try GitWorktrees.ensureExcluded(commonDir: common)

        let text = try String(contentsOf: info.appending(path: "exclude"), encoding: .utf8)
        #expect(text.hasPrefix("*.log\n"))
        #expect(text.components(separatedBy: "\n").filter { $0 == "/.agents/worktrees/" }.count == 1)
    }

    @Test func anExcludeFileThatIsNotThereIsMade() throws {
        let common = FileManager.default.temporaryDirectory.appending(path: "gw-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: common) }
        try FileManager.default.createDirectory(at: common, withIntermediateDirectories: true)
        try GitWorktrees.ensureExcluded(commonDir: common)
        let text = try String(contentsOf: common.appending(path: "info/exclude"), encoding: .utf8)
        #expect(text.contains("/.agents/worktrees/\n"))
    }

    @Test func localBranchesThenRemoteOnesNotAlreadyLocal() {
        let refs = """
            refs/heads/main
            refs/remotes/origin/HEAD
            refs/remotes/origin/main
            refs/remotes/origin/review/pr-12
            refs/remotes/my/fork/topic
            refs/heads/feature/login
            """
        let branches = GitWorktrees.parseBranches(refs, remotes: ["origin", "my/fork", "my"])
        #expect(branches == [
            .init(name: "main"),
            .init(name: "feature/login"),
            .init(name: "review/pr-12", remote: "origin"),
            .init(name: "topic", remote: "my/fork"),
        ])
    }
}
