import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// The daemon's git, bounded (#207): a call that hangs is stopped and frees what waits
/// behind it, a read never rewrites a lane's index, and nothing reads a huge untracked
/// file or keeps every line of a huge listing.
@Suite("The daemon's git is bounded", .timeLimit(.minutes(2)))
struct GitBoundsTests {
    private func git(_ arguments: [String], in folder: URL) async throws -> String {
        let outcome = try await GitProcess(arguments, in: folder).run()
        guard outcome.succeeded else {
            throw GitWorktrees.Failure(message: "git \(arguments.joined(separator: " ")): \(outcome.errors)")
        }
        return outcome.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A repository with one commit on `main`, in a folder of its own to delete.
    private func repository() async throws -> (holder: URL, top: URL) {
        let holder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsGitBounds-\(UUID().uuidString)", isDirectory: true)
        let top = holder.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: top, withIntermediateDirectories: true)
        _ = try await git(["init", "-q", "-b", "main"], in: top)
        _ = try await git(["config", "user.email", "test@example.com"], in: top)
        _ = try await git(["config", "user.name", "Test"], in: top)
        try "hello\n".write(to: top.appending(path: "README"), atomically: true, encoding: .utf8)
        _ = try await git(["add", "."], in: top)
        _ = try await git(["commit", "-q", "-m", "first"], in: top)
        return (holder, Project.standardize(top))
    }

    private func identity(of url: URL) throws -> [String] {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return ["\(attributes[.systemFileNumber] ?? 0)", "\(attributes[.size] ?? 0)",
                "\((attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"]
    }

    // MARK: Deadlines

    /// A checkout that hangs, as an LFS smudge on a dead network does: the add is stopped
    /// at its deadline, says so, and the next worktree change in the project goes ahead.
    @Test func aHungWorktreeAddIsStoppedAndFreesTheProjectsQueue() async throws {
        let (holder, top) = try await repository()
        defer { try? FileManager.default.removeItem(at: holder) }
        try "* filter=hang\n".write(to: top.appending(path: ".gitattributes"), atomically: true, encoding: .utf8)
        _ = try await git(["add", ".gitattributes"], in: top)
        _ = try await git(["commit", "-q", "-m", "attributes"], in: top)
        _ = try await git(["config", "filter.hang.smudge", "sleep 20"], in: top)

        let started = Date()
        let failure = await #expect(throws: GitWorktrees.Failure.self) {
            try await GitWorktrees.$deadlineOverride.withValue(.seconds(1)) {
                try await GitWorktrees.add(branch: "hung", path: holder.appending(path: "hung"), in: top)
            }
        }
        #expect(Date().timeIntervalSince(started) < 10, "stopped at its deadline, not when the smudge ended")
        #expect(failure?.message.contains("git worktree add was stopped after 1 second") == true,
                "it says what happened: \(failure?.message ?? "")")

        _ = try await git(["config", "--unset", "filter.hang.smudge"], in: top)
        let next = Date()
        try await GitWorktrees.add(branch: "after", path: holder.appending(path: "after"), in: top)
        #expect(Date().timeIntervalSince(next) < 10, "the queue was freed")
        #expect(FileManager.default.fileExists(atPath: holder.appending(path: "after/README").path))
    }

    @Test func aChildWhoseGrandchildHoldsItsPipeEndsWithItsOwnStatus() async {
        // The backgrounded sleep keeps stdout open after the shell has gone, as an ssh
        // ControlPersist master started by git does.
        let started = Date()
        let outcome = await ChildProcess.run(URL(fileURLWithPath: "/bin/sh"), ["-c", "sleep 20 & printf done"],
                                             deadline: .seconds(15))
        #expect(!outcome.timedOut)
        #expect(outcome.status == 0)
        #expect(outcome.text == "done")
        #expect(Date().timeIntervalSince(started) < 6)
    }

    @Test func outputPastTheLimitIsDroppedAndSaid() async {
        let outcome = await ChildProcess.run(URL(fileURLWithPath: "/bin/sh"), ["-c", "head -c 1000000 /dev/zero"],
                                             outputLimit: 1000)
        #expect(outcome.status == 0)
        #expect(outcome.output.count == 1000)
        #expect(outcome.truncated)
    }

    @Test func aBlockingRunHasADeadlineToo() {
        let started = Date()
        let outcome = ChildProcess.runBlocking(URL(fileURLWithPath: "/bin/sh"), ["-c", "exec sleep 30"],
                                               deadline: .milliseconds(500))
        #expect(outcome.timedOut)
        #expect(Date().timeIntervalSince(started) < 5)
    }

    // MARK: Read-only

    /// A file touched in a lane makes its index stale; a plain `git status` would refresh
    /// it and write the index under the lane agent. The daemon's does not.
    @Test func listingAWorktreeNeverRewritesItsIndex() async throws {
        let (holder, top) = try await repository()
        defer { try? FileManager.default.removeItem(at: holder) }
        let lane = holder.appending(path: "lane1")
        _ = try await git(["worktree", "add", "-q", "-b", "lane1", lane.path, "HEAD"], in: top)
        let index = try #require(GitStamp.gitDirectory(of: lane)).appending(path: "index")
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(120)],
                                              ofItemAtPath: lane.appending(path: "README").path)
        let before = try identity(of: index)

        let summary = DaemonAPI.WorktreeSummary(name: "lane1", root: lane, branch: "lane1", isProjectFolder: false,
                                                exists: true, madeByApp: false, agents: [])
        let statuses = await DaemonCore.statuses(of: [summary], base: "main")
        #expect(statuses[lane]?.uncommitted == 0)
        _ = try await GitWorktrees.status(in: lane)
        #expect(try identity(of: index) == before, "the daemon's reads left the lane's index alone")

        // And the test means something: git's own status, without the switch, writes it.
        _ = try await GitProcess(["status", "--porcelain"], in: lane).run()
        #expect(try identity(of: index) != before)
    }

    // MARK: Caches

    @Test func aCachedStatusMovesWhenTheLaneCommits() async throws {
        let (holder, top) = try await repository()
        defer { try? FileManager.default.removeItem(at: holder) }
        let lane = holder.appending(path: "lane")
        _ = try await git(["worktree", "add", "-q", "-b", "lane", lane.path, "HEAD"], in: top)
        try "work".write(to: lane.appending(path: "NEW"), atomically: true, encoding: .utf8)
        let summary = DaemonAPI.WorktreeSummary(name: "lane", root: lane, branch: "lane", isProjectFolder: false,
                                                exists: true, madeByApp: false, agents: [])
        let first = await DaemonCore.statuses(of: [summary], base: "main")
        #expect(first[lane] == DaemonAPI.WorktreeStatus(uncommitted: 1, unmerged: 0))

        _ = try await git(["add", "NEW"], in: lane)
        _ = try await git(["commit", "-q", "-m", "work"], in: lane)
        let second = await DaemonCore.statuses(of: [summary], base: "main")
        #expect(second[lane] == DaemonAPI.WorktreeStatus(uncommitted: 0, unmerged: 1))
    }

    @Test func aListGivesStatusesForTwelveWorktreesAtMost() async throws {
        let (holder, top) = try await repository()
        defer { try? FileManager.default.removeItem(at: holder) }
        var summaries = [DaemonAPI.WorktreeSummary(name: "repo", root: top, branch: "main", isProjectFolder: true,
                                                   exists: true, madeByApp: false, agents: [])]
        for number in 1...14 {
            let lane = holder.appending(path: "lane\(number)")
            _ = try await git(["worktree", "add", "-q", "-b", "lane\(number)", lane.path, "HEAD"], in: top)
            summaries.append(.init(name: "lane\(number)", root: lane, branch: "lane\(number)", isProjectFolder: false,
                                   exists: true, madeByApp: true, agents: number == 14 ? [UUID()] : []))
        }
        let statuses = await DaemonCore.statuses(of: summaries, base: "main")
        #expect(statuses.count == DaemonCore.statusedWorktreeLimit)
        #expect(statuses[top] != nil, "the project folder comes first")
        #expect(statuses[holder.appending(path: "lane14")] != nil, "then worktrees with agents in them")
    }

    // MARK: Changes

    @Test func aHugeUntrackedFileIsNeverRead() throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsSparse-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let huge = folder.appending(path: "huge.bin")
        #expect(FileManager.default.createFile(atPath: huge.path, contents: nil))
        let handle = try FileHandle(forWritingTo: huge)
        try handle.truncate(atOffset: 2 << 30)
        try handle.close()

        let started = Date()
        #expect(DaemonCore.untrackedCount(huge.path) == nil)
        #expect(Date().timeIntervalSince(started) < 1, "2 GB was not read to find it was too big")
    }

    @Test func theUntrackedListIsCappedAndNeverEndsInACutPath() {
        let paths = (0..<1500).map { "build/file\($0).o" }
        var data = Data(paths.joined(separator: "\0").utf8)
        data.append(0)
        let whole = GitProcess.Outcome(status: 0, output: "", errors: "", data: data)
        #expect(GitChanges.untracked(whole).count == GitChanges.untrackedLimit)

        let cut = GitProcess.Outcome(status: 0, output: "", errors: "", data: Data("a.txt\0b.txt\0half/pa".utf8),
                                     truncated: true)
        #expect(GitChanges.untracked(cut) == ["a.txt", "b.txt"])
    }
}
