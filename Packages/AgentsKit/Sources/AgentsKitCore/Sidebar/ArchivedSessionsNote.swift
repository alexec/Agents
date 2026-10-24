import Foundation

/// The line under a folder's archived sessions on its Archived page (#664), which the
/// Mac's window and the Remote both draw, as the web does: never "none" until the host
/// has said so, and never a capped page passed off as the whole archive.
public enum ArchivedSessionsNote: Equatable, Sendable {
    /// The host has not answered yet.
    case loading
    /// The host did not answer, or is offline.
    case hostSilent
    /// The host answered with none.
    case none
    /// The page holds the newest `shown` of `total`.
    case capped(shown: Int, total: Int)

    /// Nil when the list says it all. `answered` is nil while the ask is on its way;
    /// `total` is the host's count of the folder's archived sessions.
    public static func note(shown: Int, total: Int, answered: Bool?, hostOffline: Bool) -> Self? {
        if shown == 0 {
            if hostOffline || answered == false { return .hostSilent }
            return answered == nil ? .loading : ArchivedSessionsNote.none
        }
        if shown >= SidebarFolderFold.archivedShown, total > shown { return .capped(shown: shown, total: total) }
        return nil
    }

    public var text: String {
        switch self {
        case .loading: "Loading…"
        case .hostSilent: "Its machine isn’t answering"
        case .none: "No archived sessions"
        case .capped(let shown, let total): "The newest \(shown) of \(total). Search to find an older one."
        }
    }
}
