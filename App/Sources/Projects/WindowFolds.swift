import AgentsKitCore
import Foundation

extension SidebarFolds {
    /// This window's folds: in defaults, scoped by walk and by root. Every copy of the app
    /// shares one defaults domain, and a scratch window's folds are not the real window's.
    /// A walk's window (run-app, `--walk`) is a client of a scratch control plane on the
    /// standard root, so the root alone does not tell it apart.
    convenience init(locations: StoreLocations = .default, walk: String? = ControlConfig.walk) {
        self.init(scope: walk.map { ".walk:\($0)" } ?? (locations.isStandard ? "" : ".root:\(locations.name)"))
    }
}
