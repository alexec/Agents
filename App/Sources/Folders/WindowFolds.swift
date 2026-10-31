import AgentsKitCore
import Foundation

extension SidebarFolds {
    /// This window's folds, in `WindowDefaults`: a scratch window's folds are not the real
    /// window's.
    convenience init() {
        self.init(defaults: WindowDefaults.store, scope: "")
    }
}
