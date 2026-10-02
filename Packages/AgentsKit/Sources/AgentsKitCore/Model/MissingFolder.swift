import Foundation

/// An agent whose folder is not there any more (#119).
///
/// A worktree removed after its branch merged, a project folder moved or deleted, a disk
/// ejected. The session still lists and its prompt bar still takes words, so the daemon
/// says so on the record, and refuses a send with `folderGone`, rather than let a runtime
/// start in a folder that does not exist.
public struct MissingFolder: Codable, Hashable, Sendable {
    /// Its worktree's branch is still in the project's repository, so the worktree can be
    /// made again from it. False for an agent that was never in a worktree.
    public var branchKept: Bool

    public init(branchKept: Bool) {
        self.branchKept = branchKept
    }
}

/// The words every app uses for a missing folder, so the Mac, the Remote and the page say
/// the same thing. The page has its own copy in `Web/src/model/missingFolder.ts`.
public enum MissingFolderWords {
    /// Under the row's title and in the chat header, as project rows say it.
    public static let label = "Folder is missing"
    public static let continueInProject = "Continue in the project folder"
    public static let recreateWorktree = "Recreate the worktree"
    public static let archive = "Archive"

    /// Why a send was refused, naming the folder.
    public static func refusal(path: String, wasWorktree: Bool) -> String {
        "This agent's folder isn't there any more (\(path)). "
            + (wasWorktree ? "It was a worktree, and may have been removed after merging."
                           : "It may have been moved or deleted, or be on a disk that is not connected.")
    }

    /// A path with the home folder as `~`, as the rest of the app shows paths.
    public static func shortPath(_ url: URL, home: String = NSHomeDirectory()) -> String {
        let path = url.path(percentEncoded: false)
        let trimmed = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        guard !home.isEmpty, trimmed == home || trimmed.hasPrefix(home + "/") else { return trimmed }
        return "~" + trimmed.dropFirst(home.count)
    }

    /// The first words of a successor started in the project folder: which session it
    /// carries on, and how to read it (065's continue successor, `read_session`). The
    /// person's own words, if they had any in the bar, follow.
    public static func successorPrompt(title: String?, agentID: UUID, folder: String,
                                       project: String, then text: String) -> String {
        let name = title.map { "“\($0)” (\(agentID.uuidString))" } ?? agentID.uuidString
        var prompt = "Continue the work of the session \(name). Its folder, \(folder), is not there any more, "
            + "so you are in the project folder, \(project), instead. Read that session with read_session "
            + "to see what it did and what is left, then carry on."
        let said = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !said.isEmpty { prompt += "\n\n" + said }
        return prompt
    }
}

extension Agent {
    /// What a send to this agent is refused with while its folder is missing.
    public var folderGoneMessage: String {
        MissingFolderWords.refusal(path: MissingFolderWords.shortPath(cwd), wasWorktree: worktree != nil)
    }

    /// Recreate the worktree is offered: it was one, and its branch is still there.
    public var mayRecreateWorktree: Bool {
        worktree?.branch != nil && missingFolder?.branchKept == true
    }
}
