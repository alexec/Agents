import AgentsKitCore
import Foundation
import Observation

/// Which projects in the sidebar are unfolded, and which of their Archived folds are
/// open (#145), kept across launches.
///
/// In defaults, scoped by walk and by root: every copy of the app shares one defaults
/// domain, and a scratch window's folds are not the real window's. A walk's window (run-app,
/// `--walk`) is a client of a scratch control plane on the standard root, so the root alone
/// does not tell it apart.
@MainActor
@Observable
final class SidebarFolds {
    private(set) var open: Set<String>
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let key: String

    init(defaults: UserDefaults = .standard, locations: StoreLocations = .default,
         walk: String? = ControlConfig.walk) {
        self.defaults = defaults
        key = walk.map { "sidebar.folds.walk:\($0)" }
            ?? (locations.isStandard ? "sidebar.folds" : "sidebar.folds.root:\(locations.name)")
        open = Set(defaults.stringArray(forKey: key) ?? [])
    }

    /// What can be folded: a project, or one of a project's Archived folds.
    enum Fold: String {
        case project, archivedSessions, archivedWorkflows
    }

    func isOpen(_ project: ProjectKey, _ fold: Fold = .project) -> Bool {
        open.contains(Self.name(project, fold))
    }

    func set(_ project: ProjectKey, _ fold: Fold = .project, open isOpen: Bool) {
        let name = Self.name(project, fold)
        guard open.contains(name) != isOpen else { return }
        if isOpen { open.insert(name) } else { open.remove(name) }
        defaults.set(open.sorted(), forKey: key)
    }

    private static func name(_ project: ProjectKey, _ fold: Fold) -> String {
        fold == .project ? project.stored : "\(fold.rawValue):\(project.stored)"
    }
}
