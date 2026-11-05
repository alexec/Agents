import Foundation

/// What one turn changed (#3437): the files that differ between the snapshots the host took
/// as the turn began and as it ended. Drawn as the Changed files card at the end of the
/// turn, with Undo These Changes.
public struct TurnChanges: Codable, Hashable, Sendable {
    /// The turn, by its prompt's entry.
    public var turn: UUID
    /// At most 50; `more` counts the rest.
    public var files: [TurnChangedFile]
    public var more: Int?
    /// Files the agent edited that a snapshot does not hold: outside the folder, or ignored
    /// by git. Undo cannot put them back.
    public var cannotUndo: [String]?
    /// Another agent's turn ran in the same folder, so `files` names only what this agent
    /// reported editing.
    public var onlyReported: Bool?
    /// The snapshots' git trees, for the host's undo. Not drawn.
    public var before: String?
    public var after: String?
    /// Never recorded: the later `turnUndone` entry, said on this card by the fold that
    /// draws it (`TranscriptDisplayBuilder`).
    public var undone: TurnUndo?

    public init(turn: UUID, files: [TurnChangedFile], more: Int? = nil, cannotUndo: [String]? = nil,
                onlyReported: Bool? = nil, before: String? = nil, after: String? = nil, undone: TurnUndo? = nil) {
        self.turn = turn
        self.files = files
        self.more = more
        self.cannotUndo = cannotUndo
        self.onlyReported = onlyReported
        self.before = before
        self.after = after
        self.undone = undone
    }

    /// How many files the turn changed, the ones not listed counted too.
    public var count: Int { files.count + (more ?? 0) }
}

public struct TurnChangedFile: Codable, Hashable, Sendable, Identifiable {
    public var path: String
    public var relativePath: String?
    public var state: ChangeState

    public init(path: String, relativePath: String? = nil, state: ChangeState) {
        self.path = path
        self.relativePath = relativePath
        self.state = state
    }

    public var id: String { path }
    /// The path as the card shows it: within the folder where it is in it.
    public var shown: String { relativePath ?? path }
}

/// The files `changes/undoTurn` put back as they were before turn `turn` (#3437). Not drawn
/// on its own: said on that turn's card.
public struct TurnUndo: Codable, Hashable, Sendable {
    public var turn: UUID
    public var putBack: [String]

    public init(turn: UUID, putBack: [String]) {
        self.turn = turn
        self.putBack = putBack
    }
}
