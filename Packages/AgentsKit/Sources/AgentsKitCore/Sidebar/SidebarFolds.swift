import Foundation
import Observation

/// Which projects in the sidebar are unfolded, which of their Archived folds are open
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
    /// The folds that start closed and have been opened: projects, the Archived folds.
    public private(set) var open: Set<String>
    /// The folds that start open and have been closed: the groups and Workflows (#181).
    /// Kept apart so that a project nobody has touched shows its groups as it always has.
    public private(set) var closed: Set<String>
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let key: String
    @ObservationIgnored private let closedKey: String

    public init(defaults: UserDefaults = .standard, scope: String) {
        self.defaults = defaults
        key = "sidebar.folds" + scope
        closedKey = "sidebar.folded" + scope
        open = Set(defaults.stringArray(forKey: key) ?? [])
        closed = Set(defaults.stringArray(forKey: closedKey) ?? [])
    }

    /// What can be folded: a project; one of its Archived folds; one of its session
    /// groups, its pinned sessions or its Workflows.
    public enum Fold: Hashable, Sendable {
        case project, archivedSessions, archivedWorkflows
        case group(AgentGroup)
        /// The pinned sessions (#180).
        case pinned
        case workflows

        /// A project and the Archived folds start folded; the rest start open.
        public var startsOpen: Bool {
            switch self {
            case .project, .archivedSessions, .archivedWorkflows: false
            case .group, .pinned, .workflows: true
            }
        }

        var name: String {
            switch self {
            case .project: "project"
            case .archivedSessions: "archivedSessions"
            case .archivedWorkflows: "archivedWorkflows"
            case .group(let group): "group.\(group.rawValue)"
            case .pinned: "pinned"
            case .workflows: "workflows"
            }
        }
    }

    public func isOpen(_ project: ProjectKey, _ fold: Fold = .project) -> Bool {
        let name = Self.name(project, fold)
        return fold.startsOpen ? !closed.contains(name) : open.contains(name)
    }

    public func set(_ project: ProjectKey, _ fold: Fold = .project, open isOpen: Bool) {
        let name = Self.name(project, fold)
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

    /// The projects whose Archived fold is open: the ones a client holds a page of
    /// archived sessions for (#165).
    public var openArchivedFolds: Set<ProjectKey> {
        let prefix = Fold.archivedSessions.name + ":"
        return Set(open.compactMap { $0.hasPrefix(prefix) ? ProjectKey(stored: String($0.dropFirst(prefix.count))) : nil })
    }

    private static func name(_ project: ProjectKey, _ fold: Fold) -> String {
        fold == .project ? project.stored : "\(fold.name):\(project.stored)"
    }
}

/// A row under one of a project's folds, known by the fold as well as by what it shows
/// (#237).
///
/// A session that moves from one fold to another (Done to Parked, to Archived) used to
/// keep its own id as it went. SwiftUI's outline list read that as the same item, and
/// the rows it told `NSOutlineView` to take out no longer matched the rows it had:
/// "error removing child indexes (6) in parent (which has 5 children)". AppKit catches
/// that and goes on. From then on, the sidebar draws rows twice or leaves them out,
/// and the window looks hung. With the fold in its id, a move is one row
/// taken out of a fold and a new one put into another.
///
/// A closed fold is given no rows at all, as a folded project already is. `NSOutlineView`
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
