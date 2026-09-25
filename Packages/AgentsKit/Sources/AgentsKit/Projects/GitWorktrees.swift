import Foundation
import AgentsKitCore

/// The git behind worktrees (030): making one, listing them, and taking one away.
///
/// Every command is the person's own git through `GitProcess`, so it has their config
/// and their hooks, and never asks anything. Each one that fails throws its own words,
/// because "fatal: 'agents/x' is already checked out" says more than any message of
/// ours could.
public enum GitWorktrees {
    public struct Failure: Error, Sendable, Equatable {
        public var message: String
        public init(message: String) { self.message = message }
    }

    /// Where a folder sits in its repository.
    public struct Repository: Sendable, Equatable {
        /// The top of the checkout the folder is in.
        public var toplevel: URL
        /// The folder's path below `toplevel`, ending in `/`, or empty at the top.
        public var prefix: String
        /// The `.git` every worktree of the repository shares.
        public var commonDir: URL

        /// Where the app's worktrees of this checkout go.
        public var worktreesFolder: URL {
            toplevel.appending(path: WorktreeName.folder, directoryHint: .isDirectory)
        }
    }

    /// One entry of `git worktree list --porcelain`.
    public struct Entry: Sendable, Equatable {
        public var path: URL
        public var head: String?
        /// Without `refs/heads/`. Nil when detached.
        public var branch: String?
        public var isBare = false
        public var isLocked = false
        /// Git knows its folder has gone.
        public var isPrunable = false

        public init(path: URL, head: String? = nil, branch: String? = nil, isBare: Bool = false,
                    isLocked: Bool = false, isPrunable: Bool = false) {
            self.path = path
            self.head = head
            self.branch = branch
            self.isBare = isBare
            self.isLocked = isLocked
            self.isPrunable = isPrunable
        }
    }

    /// The line that keeps the app's worktrees out of the project's own status.
    public static let excludeLine = "/\(WorktreeName.folder)/"

    // MARK: Reading

    /// The repository a folder is in, or nil when it is in none.
    public static func repository(of folder: URL) async -> Repository? {
        guard let outcome = try? await git(["rev-parse", "--path-format=absolute", "--show-toplevel",
                                            "--git-common-dir", "--show-prefix"], in: folder)
        else { return nil }
        let lines = outcome.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.count >= 2, !lines[0].isEmpty else { return nil }
        return Repository(toplevel: URL(filePath: lines[0], directoryHint: .isDirectory),
                          prefix: lines.count > 2 ? lines[2] : "",
                          commonDir: URL(filePath: lines[1], directoryHint: .isDirectory))
    }

    /// Whether there is any commit to base a worktree on.
    public static func hasCommit(in folder: URL) async -> Bool {
        (try? await git(["rev-parse", "--verify", "-q", "HEAD"], in: folder)) != nil
    }

    /// The branch checked out, or the commit when HEAD is detached.
    public static func base(in folder: URL) async -> String? {
        guard let name = try? await git(["rev-parse", "--abbrev-ref", "HEAD"], in: folder) else { return nil }
        if name != "HEAD" { return name }
        return try? await git(["rev-parse", "HEAD"], in: folder)
    }

    /// Whether a local branch of that name exists.
    public static func branchExists(_ branch: String, in folder: URL) async -> Bool {
        (try? await git(["show-ref", "--verify", "-q", "refs/heads/\(branch)"], in: folder)) != nil
    }

    public static func list(in folder: URL) async throws -> [Entry] {
        parse(try await git(["worktree", "list", "--porcelain"], in: folder))
    }

    /// Every local branch, then every remote one with no local branch of its name, most
    /// recently committed to first. A remote's `HEAD` is a pointer, not a branch.
    public static func branches(in folder: URL) async throws -> [DaemonAPI.BranchSummary] {
        let refs = try await git(["for-each-ref", "--sort=-committerdate", "--format=%(refname)",
                                  "refs/heads", "refs/remotes"], in: folder)
        return parseBranches(refs, remotes: try await git(["remote"], in: folder)
            .split(separator: "\n").map(String.init))
    }

    /// `refs/heads/…` and `refs/remotes/<remote>/…` lines, as branches. The remotes are
    /// needed because a remote's name can itself have a `/` in it.
    public static func parseBranches(_ refs: String, remotes: [String]) -> [DaemonAPI.BranchSummary] {
        var local: [DaemonAPI.BranchSummary] = []
        var remote: [DaemonAPI.BranchSummary] = []
        for line in refs.split(separator: "\n").map(String.init) {
            if line.hasPrefix("refs/heads/") {
                local.append(.init(name: String(line.dropFirst(11))))
            } else if line.hasPrefix("refs/remotes/") {
                let rest = String(line.dropFirst(13))
                guard let owner = remotes.sorted(by: { $0.count > $1.count })
                        .first(where: { rest.hasPrefix($0 + "/") }) else { continue }
                let name = String(rest.dropFirst(owner.count + 1))
                guard !name.isEmpty, name != "HEAD" else { continue }
                remote.append(.init(name: name, remote: owner))
            }
        }
        var seen = Set(local.map(\.name))
        var result = local
        for branch in remote where seen.insert(branch.name).inserted { result.append(branch) }
        return result
    }

    /// Lines of `git status --porcelain`: what is changed and not committed.
    public static func statusCount(in folder: URL) async throws -> Int {
        try await git(["status", "--porcelain"], in: folder)
            .split(separator: "\n").count
    }

    /// Uncommitted changes outside the app's own `.agents` folder (038). A workflow just
    /// written there, the babysitter included, is not somebody's work in progress, and
    /// counting it would refuse every pull request checked out in the project folder.
    public static func workInProgressCount(in folder: URL) async throws -> Int {
        try await git(["status", "--porcelain", "--", ".", ":(exclude).agents"], in: folder)
            .split(separator: "\n").count
    }

    /// Whether every commit on `branch` is already in `base`.
    public static func isAncestor(_ branch: String, of base: String, in folder: URL) async -> Bool {
        (try? await git(["merge-base", "--is-ancestor", branch, base], in: folder)) != nil
    }

    /// The URL a remote is configured with, or nil when there is no such remote. As
    /// written, before any `insteadOf` rewriting: what the project says it is.
    public static func remoteURL(_ remote: String, in folder: URL) async -> String? {
        try? await git(["config", "--get", "remote.\(remote).url"], in: folder)
    }

    /// The URL of the remote a local branch tracks, or nil when it tracks none (038 R4).
    public static func upstreamURL(of branch: String, in folder: URL) async -> String? {
        guard let remote = try? await git(["config", "--get", "branch.\(branch).remote"], in: folder),
              !remote.isEmpty else { return nil }
        // A branch may track a URL directly rather than a named remote.
        if remote.contains("/") || remote.contains(":") { return remote }
        return await remoteURL(remote, in: folder)
    }

    /// How far the branch checked out in `folder` is ahead of and behind what it tracks,
    /// or nil when it tracks nothing (038 R10).
    public static func aheadBehind(in folder: URL) async -> (ahead: Int, behind: Int)? {
        guard let counts = try? await git(["rev-list", "--left-right", "--count", "HEAD...@{upstream}"], in: folder)
        else { return nil }
        let parts = counts.split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        return (parts[0], parts[1])
    }

    /// How many commits `branch` has that `base` doesn't, or nil when either is unknown.
    public static func commitCount(from base: String, to branch: String, in folder: URL) async -> Int? {
        guard let count = try? await git(["rev-list", "--count", "\(base)..\(branch)"], in: folder)
        else { return nil }
        return Int(count)
    }

    // MARK: Writing

    /// Fetch `refspec` from `remote`, which is a remote's name or a URL (038 R5).
    public static func fetch(remote: String, refspec: String, in folder: URL) async throws {
        _ = try await git(["fetch", "--no-tags", remote, refspec], in: folder)
    }

    /// A new worktree at `path` on a branch that already exists and is not checked out
    /// anywhere (038 R5): a pull request's own branch, never a new `agents/` one.
    public static func add(existingBranch branch: String, path: URL, in folder: URL) async throws {
        _ = try await git(["worktree", "add", path.path(percentEncoded: false), branch], in: folder)
    }

    /// A new worktree at `path` on a new local branch that tracks `upstream`.
    public static func add(trackingBranch branch: String, upstream: String, path: URL,
                           in folder: URL) async throws {
        _ = try await git(["worktree", "add", "--track", "-b", branch, path.path(percentEncoded: false), upstream],
                          in: folder)
    }

    /// A new worktree at `path` on a new branch from what `folder` has checked out.
    /// Git refuses an existing branch itself, which is the last word on a clash.
    public static func add(branch: String, path: URL, in folder: URL) async throws {
        _ = try await git(["worktree", "add", "-b", branch, path.path(percentEncoded: false), "HEAD"],
                          in: folder)
    }

    /// A new worktree at `path` on a branch that is already there. One only a remote
    /// has becomes a local branch of the same name that tracks it.
    public static func add(existing branch: DaemonAPI.BranchSummary, path: URL, in folder: URL) async throws {
        let at = path.path(percentEncoded: false)
        if let remote = branch.remote {
            _ = try await git(["worktree", "add", "--track", "-b", branch.name, at, "\(remote)/\(branch.name)"],
                              in: folder)
        } else {
            _ = try await git(["worktree", "add", at, branch.name], in: folder)
        }
    }

    public static func remove(_ path: URL, force: Bool, in folder: URL) async throws {
        _ = try await git(["worktree", "remove"] + (force ? ["--force"] : []) + [path.path(percentEncoded: false)],
                          in: folder)
    }

    /// Forget worktrees whose folders have gone.
    public static func prune(in folder: URL) async throws {
        _ = try await git(["worktree", "prune"], in: folder)
    }

    public static func deleteBranch(_ branch: String, force: Bool, in folder: URL) async throws {
        _ = try await git(["branch", force ? "-D" : "-d", branch], in: folder)
    }

    /// Put the app's worktrees folder in this clone's own exclude file, once. That file
    /// is never committed, so the project's tracked files are not touched (FR-010).
    public static func ensureExcluded(commonDir: URL) throws {
        let info = commonDir.appending(path: "info", directoryHint: .isDirectory)
        let exclude = info.appending(path: "exclude")
        let existing = (try? String(contentsOf: exclude, encoding: .utf8)) ?? ""
        let lines = existing.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard !lines.contains(excludeLine) else { return }
        do {
            try FileManager.default.createDirectory(at: info, withIntermediateDirectories: true)
            let joiner = existing.isEmpty || existing.hasSuffix("\n") ? "" : "\n"
            let added = existing + joiner
                + "# Worktrees the Agents app makes for its agents.\n" + excludeLine + "\n"
            try added.write(to: exclude, atomically: true, encoding: .utf8)
        } catch {
            throw Failure(message: "Could not keep the worktrees out of the project: \(error.localizedDescription)")
        }
    }

    // MARK: Parsing

    public static func parse(_ porcelain: String) -> [Entry] {
        var entries: [Entry] = []
        var current: Entry?
        for raw in porcelain.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.isEmpty {
                if let done = current { entries.append(done) }
                current = nil
                continue
            }
            let (key, value) = line.firstIndex(of: " ").map {
                (String(line[..<$0]), String(line[line.index(after: $0)...]))
            } ?? (line, "")
            switch key {
            case "worktree":
                if let done = current { entries.append(done) }
                current = Entry(path: URL(filePath: value, directoryHint: .isDirectory))
            case "HEAD": current?.head = value
            case "branch":
                current?.branch = value.hasPrefix("refs/heads/") ? String(value.dropFirst(11)) : value
            case "detached": current?.branch = nil
            case "bare": current?.isBare = true
            case "locked": current?.isLocked = true
            case "prunable": current?.isPrunable = true
            default: break
            }
        }
        if let done = current { entries.append(done) }
        return entries
    }

    // MARK: Running

    /// Run git in `folder`, and give back what it printed, trimmed, or throw what it
    /// said when it failed.
    @discardableResult
    static func git(_ arguments: [String], in folder: URL) async throws -> String {
        let outcome: GitProcess.Outcome
        do {
            outcome = try await GitProcess(arguments, in: folder).run()
        } catch GitProcess.LaunchError.notInstalled {
            throw Failure(message: "Git is not installed on this Mac.")
        }
        guard outcome.succeeded else {
            let said = outcome.errors.trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure(message: said.isEmpty ? "git \(arguments.first ?? "") failed." : said)
        }
        return outcome.output.trimmingCharacters(in: .newlines)
    }
}
