import Foundation

/// Why an archived agent is not deleted yet (051, #398).
///
/// Asked before the age rule deletes one, and before the person's Delete does: a run or
/// work in its worktree refuses it. Being open only holds it from the age rule; the
/// person asking to delete it is usually the one looking at it.
public enum Hold: String, Codable, Hashable, Sendable, CaseIterable {
    /// Its app-made worktree has changes that are not committed, or commits not merged.
    case worktreeHasWork
    /// A workflow run it belongs to has not finished.
    case workflowRunning
    /// A window or a device is reading it, or read it in the last few minutes.
    case openInWindow
}

/// Why an agent was deleted, for `agent.deleted`'s details.
public enum DeletedBecause: String, Codable, Hashable, Sendable {
    case age, person
}
