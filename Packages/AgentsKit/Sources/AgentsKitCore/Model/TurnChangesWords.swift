import Foundation

/// The words of the Changed files card at the end of a turn (#3437), on the Mac and the
/// Remote. `Web/src/model/turnChanges.ts` says the same on the web page.
public enum TurnChangesWords {
    public static let symbol = "doc.on.doc"
    public static let undo = "Undo These Changes"
    public static let undoHelp = "Put these files back as they were before this turn"
    public static let undoing = "Undoing…"
    /// The question when a file changed again after the turn.
    public static let confirmTitle = "Undo these changes?"
    public static let confirmUndo = "Undo Anyway"
    public static let onlyReported = "Another agent worked in this folder at the same time, so this lists only the files this agent edited."

    /// "Changed 3 files".
    public static func title(_ changes: TurnChanges) -> String {
        let n = changes.count
        return n == 1 ? "Changed 1 file" : "Changed \(n) files"
    }

    /// "and 12 more", under the files listed.
    public static func more(_ n: Int) -> String { "and \(n) more" }

    public static func stateSymbol(_ state: ChangeState) -> String {
        switch state {
        case .added, .untracked: "plus.circle"
        case .deleted: "minus.circle"
        default: "pencil.circle"
        }
    }

    public static func stateWord(_ state: ChangeState) -> String {
        switch state {
        case .added, .untracked: "Added"
        case .deleted: "Deleted"
        default: "Changed"
        }
    }

    /// The files undo cannot put back, by name.
    public static func cannotUndo(_ paths: [String]) -> String {
        let names = paths.map { URL(filePath: $0).lastPathComponent }.formatted(.list(type: .and))
        return "Undo cannot put back \(names): \(paths.count == 1 ? "it is" : "they are") outside the folder or ignored by git."
    }

    /// What the question says: which files changed after the turn.
    public static func confirmMessage(_ paths: [String]) -> String {
        let names = paths.map { URL(filePath: $0).lastPathComponent }.formatted(.list(type: .and))
        return "\(names) changed again after this turn. Undo puts \(paths.count == 1 ? "it" : "them") back as before the turn, and the later changes go too."
    }

    /// The card's line once undone.
    public static func undone(_ undo: TurnUndo) -> String {
        let n = undo.putBack.count
        return n == 1 ? "Undone: 1 file is back as it was before this turn." : "Undone: \(n) files are back as they were before this turn."
    }

    public static func refusal(_ error: any Error) -> String {
        if let error = error as? JSONRPCError, error.code == JSONRPCError.methodNotFound {
            return "This Mac’s Agents is too old to undo. Update it."
        }
        if let error = error as? JSONRPCError { return error.message }
        return "The Mac can’t be reached. Try again when it is."
    }
}
