import Foundation
import Observation

/// Which folders in the sidebar are unfolded, which of their Archived folds are open
/// (#145), and which of their session groups and Workflows are folded (#181), kept
/// across launches.
///
/// The Mac's window and the Remote keep them the same way (#226), each in its own
/// defaults: folds are where one screen was left, not something the work says.
///
/// `scope` keeps one copy's folds from another's that shares its defaults: on the Mac,
/// every copy of the app shares one defaults domain, and a scratch window's folds are
/// not the real window's (see the window's `SidebarFolds.window`).
@MainActor
@Observable
public final class SidebarFolds {
    /// The folds that start closed and have been opened: folders, the Archived folds, a
    /// folder's Workflows (#885).
    public private(set) var open: Set<String>
    /// The folds that start open and have been closed: the groups (#181).
    /// Kept apart so that a folder nobody has touched shows its groups as it always has.
    public private(set) var closed: Set<String>
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let key: String
    @ObservationIgnored private let closedKey: String
    /// The sessions whose children are shown (#835), the last opened last. They start
    /// folded; only the last `sessionsKept` opened are kept, so the list stays small.
    public private(set) var openSessions: [UUID]
    @ObservationIgnored private let sessionsKey: String
    nonisolated public static let sessionsKept = 200

    public init(defaults: UserDefaults = .standard, scope: String) {
        self.defaults = defaults
        key = "sidebar.folds" + scope
        closedKey = "sidebar.folded" + scope
        sessionsKey = "sidebar.openSessions" + scope
        open = Set(defaults.stringArray(forKey: key) ?? [])
        closed = Set(defaults.stringArray(forKey: closedKey) ?? [])
        openSessions = (defaults.stringArray(forKey: sessionsKey) ?? []).compactMap(UUID.init(uuidString:))
    }

    /// Whether a session's children are shown under it (#835). Folded by default.
    public func isOpen(session id: UUID) -> Bool { openSessions.contains(id) }

    public func set(session id: UUID, open isOpen: Bool) {
        guard openSessions.contains(id) != isOpen else { return }
        if isOpen {
            openSessions.append(id)
            if openSessions.count > Self.sessionsKept { openSessions.removeFirst(openSessions.count - Self.sessionsKept) }
        } else {
            openSessions.removeAll { $0 == id }
        }
        defaults.set(openSessions.map(\.uuidString), forKey: sessionsKey)
    }

    /// What can be folded: a folder; one of its Archived folds; one of its session
    /// groups, its Recently archived sessions group, its pinned sessions or its Workflows.
    public enum Fold: Hashable, Sendable {
        case folder, archivedSessions, archivedWorkflows, recentArchivedSessions
        case group(AgentGroup)
        /// The pinned sessions (#180).
        case pinned
        case workflows
        /// A folder's sessions (#495): the rows' fold in their ids, and the Sessions row's
        /// fold (#2312), open until closed.
        case sessions
        /// One of the smart rows at the sidebar's top (#495), across every folder.
        case smart(SidebarSmartRow)

        /// A folder, the Archived folds and a folder's Workflows (Alex, #885) start
        /// folded; the rest start open.
        public var startsOpen: Bool {
            switch self {
            case .folder, .archivedSessions, .archivedWorkflows, .workflows: false
            case .group, .pinned, .sessions, .recentArchivedSessions: true
            case .smart(let row): row.startsOpen
            }
        }

        var name: String {
            switch self {
            case .folder: "folder"
            case .archivedSessions: "archivedSessions"
            case .archivedWorkflows: "archivedWorkflows"
            case .recentArchivedSessions: "recentArchivedSessions"
            case .group(let group): "group.\(group.rawValue)"
            case .pinned: "pinned"
            case .workflows: "workflows"
            case .sessions: "sessions"
            case .smart(let row): "smart.\(row.rawValue)"
            }
        }
    }

    public func isOpen(_ folder: FolderKey, _ fold: Fold = .folder) -> Bool {
        let name = Self.name(folder, fold)
        return fold.startsOpen ? !closed.contains(name) : open.contains(name)
    }

    public func set(_ folder: FolderKey, _ fold: Fold = .folder, open isOpen: Bool) {
        let name = Self.name(folder, fold)
        if fold.startsOpen {
            guard closed.contains(name) == isOpen else { return }
            if isOpen { closed.remove(name) } else { closed.insert(name) }
            defaults.set(closed.sorted(), forKey: closedKey)
        } else {
            guard open.contains(name) != isOpen else { return }
            if isOpen { open.insert(name) } else { open.remove(name) }
            defaults.set(open.sorted(), forKey: key)
        }
    }

    /// Whether one of the smart rows (#495) is open: not a folder's, so kept by name alone.
    public func isOpen(_ row: SidebarSmartRow) -> Bool {
        let name = Fold.smart(row).name
        return row.startsOpen ? !closed.contains(name) : open.contains(name)
    }

    public func set(_ row: SidebarSmartRow, open isOpen: Bool) {
        let name = Fold.smart(row).name
        if row.startsOpen {
            guard closed.contains(name) == isOpen else { return }
            if isOpen { closed.remove(name) } else { closed.insert(name) }
            defaults.set(closed.sorted(), forKey: closedKey)
        } else {
            guard open.contains(name) != isOpen else { return }
            if isOpen { open.insert(name) } else { open.remove(name) }
            defaults.set(open.sorted(), forKey: key)
        }
    }

    /// The folders whose Archived fold is open: the ones a client holds a page of
    /// archived sessions for (#165).
    public var openArchivedFolds: Set<FolderKey> {
        let prefix = Fold.archivedSessions.name + ":"
        return Set(open.compactMap { $0.hasPrefix(prefix) ? FolderKey(stored: String($0.dropFirst(prefix.count))) : nil })
    }

    private static func name(_ folder: FolderKey, _ fold: Fold) -> String {
        fold == .folder ? folder.stored : "\(fold.name):\(folder.stored)"
    }
}

/// A row under one of a folder's folds, known by the fold as well as by what it shows
/// (#237).
///
/// A session that moves from one fold to another (Done to Paused, to Archived) used to
/// keep its own id as it went. SwiftUI's outline list read that as the same item, and
/// the rows it told `NSOutlineView` to take out no longer matched the rows it had:
/// "error removing child indexes (6) in parent (which has 5 children)". AppKit catches
/// that and goes on. From then on, the sidebar draws rows twice or leaves them out,
/// and the window looks hung. With the fold in its id, a move is one row
/// taken out of a fold and a new one put into another.
///
/// A closed fold is given no rows at all, as a folded folder already is. `NSOutlineView`
/// does not follow the children of an item it has not expanded, so rows that came and
/// went under a closed fold left the two counts apart the same way.
public struct FoldedRow<Item: Identifiable>: Identifiable {
    public struct ID: Hashable {
        public let fold: SidebarFolds.Fold
        public let item: Item.ID
    }

    public let fold: SidebarFolds.Fold
    public let item: Item

    public var id: ID { ID(fold: fold, item: item.id) }

    public static func rows(_ items: some Sequence<Item>, in fold: SidebarFolds.Fold) -> [FoldedRow] {
        items.map { FoldedRow(fold: fold, item: $0) }
    }
}
