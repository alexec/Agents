import Foundation

/// Undo (⌘Z) for an optimistic action that has an inverse (#4793), as Archive has one
/// (`ArchiveUndo`, #1534): Unarchive, Rename, the labels, Mute or Unmute, and Later. The
/// action is done at once; a toast says what it did and offers Undo for `ToastTime.undo`
/// seconds, and ⌘Z does the same while it shows. Undo sends the inverse, and offers no Undo
/// of its own.
///
/// "End this wait?" and "Stop <machine>?" stay confirms: their effect cannot come back.
/// The page has its own copy of the words (`changeUndoLine` in
/// `Web/src/model/changeUndo.ts`), held to `Fixtures/web/undo/lines.json`.
public struct SessionUndo: Equatable, Sendable, Identifiable {
    /// What was done, for the words.
    public enum Change: Equatable, Sendable {
        case unarchived
        /// The new title; empty gives the runtime's title back.
        case renamed(to: String)
        case labels(add: [String], remove: [String])
        case muted(Bool)
        case later
    }

    /// What Undo sends.
    public enum Inverse: Equatable, Sendable {
        case archive(UUID)
        /// The title it had: the person's, or empty for the runtime's.
        case rename(UUID, to: String)
        case labels(UUID, add: [String], remove: [String])
        case mute(UUID, Bool)
        case bringBack(NeedRequest)
    }

    /// Each action its own toast, so a second one starts its seconds again.
    public let id: UUID
    public let line: String
    /// The Session menu's item while the toast shows: "Undo Rename".
    public let menuTitle: String
    public let inverse: Inverse

    public init(id: UUID = UUID(), change: Change, title: String?, inverse: Inverse) {
        self.id = id
        self.line = Self.line(change, title: title)
        self.menuTitle = Self.menuTitle(change)
        self.inverse = inverse
    }

    /// What VoiceOver says when the toast comes: the line, then that Undo is there.
    public var announcement: String {
        (line.hasSuffix(".") ? line : line + ".") + " " + ArchiveUndo.undoLabel
    }

    // MARK: Made from the record before the action

    /// Unarchive: Undo archives it again.
    public static func unarchived(_ agent: Agent) -> SessionUndo? {
        guard agent.state == .archived else { return nil }
        return SessionUndo(change: .unarchived, title: agent.title, inverse: .archive(agent.id))
    }

    /// Rename: Undo gives the title it had, the person's or the runtime's.
    public static func renamed(_ agent: Agent, to title: String) -> SessionUndo? {
        let new = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let back = agent.titleIsPersons ? (agent.title ?? "") : ""
        guard new != back.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        return SessionUndo(change: .renamed(to: new), title: agent.title, inverse: .rename(agent.id, to: back))
    }

    /// A label change: Undo removes what this added and adds back what this removed. Only
    /// what changed: a label that was there already is not taken away by Undo.
    public static func labels(_ agent: Agent, add: [String], remove: [String]) -> SessionUndo? {
        let held = Set(agent.labels.map(\.normalizedValue))
        let added = add.filter { !held.contains(SessionLabelPolicy.key($0)) }
        let removed = agent.labels.filter { label in remove.contains { SessionLabelPolicy.key($0) == label.normalizedValue } }
            .map(\.value)
        guard !added.isEmpty || !removed.isEmpty else { return nil }
        return SessionUndo(change: .labels(add: added, remove: removed), title: agent.title,
                           inverse: .labels(agent.id, add: removed, remove: added))
    }

    /// Mute or Unmute: Undo sets it back.
    public static func muted(_ agent: Agent, _ muted: Bool) -> SessionUndo? {
        guard agent.isMuted != muted else { return nil }
        return SessionUndo(change: .muted(muted), title: agent.title, inverse: .mute(agent.id, !muted))
    }

    /// Later on a request: Undo is Bring Back Now.
    public static func later(_ request: NeedRequest) -> SessionUndo {
        SessionUndo(change: .later, title: request.title, inverse: .bringBack(request))
    }

    // MARK: Words

    public static func line(_ change: Change, title: String?) -> String {
        let shown = "“\(shown(title))”"
        switch change {
        case .unarchived: return "Unarchived \(shown)"
        case .renamed(let to):
            let to = to.trimmingCharacters(in: .whitespacesAndNewlines)
            return to.isEmpty ? "Gave \(shown) its runtime’s title" : "Renamed \(shown) to “\(to)”"
        case .labels(let add, let remove):
            if add.count == 1, remove.isEmpty { return "Added the label “\(add[0])” to \(shown)" }
            if remove.count == 1, add.isEmpty { return "Removed the label “\(remove[0])” from \(shown)" }
            return "Changed the labels of \(shown)"
        case .muted(let muted): return muted ? "Muted \(shown)" : "Unmuted \(shown)"
        case .later: return "Moved \(shown) to Later"
        }
    }

    public static func menuTitle(_ change: Change) -> String {
        switch change {
        case .unarchived: return "Undo Unarchive"
        case .renamed: return "Undo Rename"
        case .labels: return "Undo Labels"
        case .muted(let muted): return muted ? "Undo Mute" : "Undo Unmute"
        case .later: return "Undo Later"
        }
    }

    private static func shown(_ title: String?) -> String {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "Untitled" : trimmed
    }
}
