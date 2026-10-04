import AgentsKitCore
import Foundation
import Observation

/// Which projects in the sidebar are unfolded, which of their Archived folds are open
/// (#145), and which of their session groups and Workflows are folded (#181), kept
/// across launches.
///
/// In defaults, scoped by walk and by root: every copy of the app shares one defaults
/// domain, and a scratch window's folds are not the real window's. A walk's window (run-app,
/// `--walk`) is a client of a scratch control plane on the standard root, so the root alone
/// does not tell it apart.
@MainActor
@Observable
final class SidebarFolds {
    /// The folds that start closed and have been opened: projects, the Archived folds.
    private(set) var open: Set<String>
    /// The folds that start open and have been closed: the groups and Workflows (#181).
    /// Kept apart so that a project nobody has touched shows its groups as it always has.
    private(set) var closed: Set<String>
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let key: String
    @ObservationIgnored private let closedKey: String

    init(defaults: UserDefaults = .standard, locations: StoreLocations = .default,
         walk: String? = ControlConfig.walk) {
        self.defaults = defaults
        let scope = walk.map { ".walk:\($0)" } ?? (locations.isStandard ? "" : ".root:\(locations.name)")
        key = "sidebar.folds" + scope
        closedKey = "sidebar.folded" + scope
        open = Set(defaults.stringArray(forKey: key) ?? [])
        closed = Set(defaults.stringArray(forKey: closedKey) ?? [])
    }

    /// What can be folded: a project; one of its Archived folds; one of its session
    /// groups or its Workflows.
    enum Fold: Hashable {
        case project, archivedSessions, archivedWorkflows
        case group(AgentGroup)
        case workflows

        /// A project and the Archived folds start folded; the rest start open.
        var startsOpen: Bool {
            switch self {
            case .project, .archivedSessions, .archivedWorkflows: false
            case .group, .workflows: true
            }
        }

        var name: String {
            switch self {
            case .project: "project"
            case .archivedSessions: "archivedSessions"
            case .archivedWorkflows: "archivedWorkflows"
            case .group(let group): "group.\(group.rawValue)"
            case .workflows: "workflows"
            }
        }
    }

    func isOpen(_ project: ProjectKey, _ fold: Fold = .project) -> Bool {
        let name = Self.name(project, fold)
        return fold.startsOpen ? !closed.contains(name) : open.contains(name)
    }

    func set(_ project: ProjectKey, _ fold: Fold = .project, open isOpen: Bool) {
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

    private static func name(_ project: ProjectKey, _ fold: Fold) -> String {
        fold == .project ? project.stored : "\(fold.name):\(project.stored)"
    }
}
