import Foundation

/// What Activity ▸ Worktrees says about a host's worktrees together (#790): how many,
/// how many idle, and how much they hold. The window and the Remote say it with these
/// words, and the web page with its port of them (`Web/src/model/worktrees.ts`).
public struct WorktreeTally: Hashable, Sendable {
    public var count = 0
    public var idle = 0
    public var bytes: Int64 = 0
    public var idleBytes: Int64 = 0
    /// Some walk ran out, so the sums are "over".
    public var partial = false
    /// Some are not measured yet.
    public var unmeasured = 0

    public init(_ worktrees: some Sequence<DaemonAPI.WorktreeSummary>) {
        for worktree in worktrees {
            count += 1
            if worktree.isIdle { idle += 1 }
            guard let size = worktree.size else {
                unmeasured += 1
                continue
            }
            bytes += size.bytes
            if worktree.isIdle { idleBytes += size.bytes }
            partial = partial || size.partial
        }
    }

    public init(_ groups: [DaemonAPI.FolderWorktrees]) {
        self.init(groups.flatMap(\.worktrees))
    }

    /// The Activity row's tooltip, and VoiceOver's value: "12 worktrees, 5 idle".
    public var rowWords: String? {
        guard count > 0 else { return nil }
        return "\(count) \(count == 1 ? "worktree" : "worktrees"), \(idle) idle"
    }

    /// The line at the top of the page: "Worktrees hold 38.2 GB, 30.1 GB of it idle."
    public var pageLine: String {
        guard count > 0 else { return Self.empty }
        guard unmeasured < count else { return "Measuring \(count == 1 ? "1 worktree" : "\(count) worktrees")…" }
        let over = partial ? "over " : ""
        return "Worktrees hold \(over)\(DiskSpace.words(bytes)), \(DiskSpace.words(idleBytes)) of it idle."
    }

    public static let empty = "No worktrees. A session started in a new worktree makes one."
    /// The page's intro, under its title.
    public static let intro = "Every folder's worktrees and how much each holds on disk. Idle ones, with no session in them, come first, largest first."
    /// A row's size before its walk is done.
    public static let measuring = "Measuring…"

    /// After Remove build output: "Freed 3.2 GB: build, Web/node_modules." or that there was none.
    public static func freedWords(_ removed: DaemonAPI.BuildOutputRemoved) -> String {
        guard !removed.removed.isEmpty else { return "No build output to remove." }
        return "Freed \(removed.freed.words): \(removed.removed.joined(separator: ", "))."
    }

    /// What Remove… asks before it loses work, as Folder Settings asked it (030).
    public static func removalMessage(_ check: DaemonAPI.RemovalCheck, branch: String?) -> String {
        var lost: [String] = []
        if check.uncommitted == 1 { lost.append("1 uncommitted change") }
        if check.uncommitted > 1 { lost.append("\(check.uncommitted) uncommitted changes") }
        if check.unmerged { lost.append("commits that are not merged") }
        return "This loses \(lost.joined(separator: " and ")), and removes its branch \(branch ?? "")."
    }

    /// The prompt Clean up worktrees offers a new session in the folder.
    public static let cleanUpPrompt = "Remove worktrees and delete branches for any work that has been merged to the default branch."
}
