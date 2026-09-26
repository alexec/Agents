import Foundation

/// Where an agent is to move (053): into a new worktree, into one already there, or back
/// to its project folder.
///
/// A move changes the folder an agent works in during its life. It is only ever made
/// between turns, because the one thing every runtime honours is the folder it is given
/// when a session starts, and the daemon already starts a fresh runtime for every turn.
public enum MoveTarget: Codable, Hashable, Sendable {
    /// A worktree made for the move, from the commit the agent's current folder has
    /// checked out. Named from the name given, or from the agent's title.
    case newWorktree(name: String?)
    /// A worktree of the project's repository that is already there.
    case existing(URL)
    /// The project folder the agent was started from.
    case projectFolder
}

/// Who asked for a move. The agent asked in order to carry on working, so it is started
/// again once moved; a move the person made starts nothing.
public enum MoveAsker: String, Codable, Hashable, Sendable {
    case agent
    case person
}

/// A move asked for and not yet made: kept on the agent's record so it survives a
/// restart, and applied when the turn it was asked in ends.
public struct PendingMove: Codable, Hashable, Sendable {
    public var target: MoveTarget
    /// Take away the worktree the agent leaves, on 030's terms. Only with `projectFolder`.
    public var removeLeft: Bool
    /// Remove it even though uncommitted or unmerged work would go with it. Only with
    /// `removeLeft`: the confirmation 030 asks the person for.
    public var discardChanges: Bool
    public var askedBy: MoveAsker
    public var askedAt: Date

    public init(target: MoveTarget, removeLeft: Bool = false, discardChanges: Bool = false,
                askedBy: MoveAsker, askedAt: Date) {
        self.target = target
        self.removeLeft = removeLeft
        self.discardChanges = discardChanges
        self.askedBy = askedBy
        self.askedAt = askedAt
    }
}
