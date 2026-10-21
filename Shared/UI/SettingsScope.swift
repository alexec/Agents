/// Settings' groups (#1759, spec 736 FR-022), the same on the window's rail, the Remote's
/// Settings and the page's: what is kept on this device only, what is the person's and
/// follows them, and what is the control plane's. The window's panes for each are
/// `SettingsScope.panes`; a pane added later goes there.
enum SettingsScope: CaseIterable {
    case thisDevice, you, controlPlane

    var title: String {
        switch self {
        case .thisDevice: "This device"
        case .you: "You"
        case .controlPlane: "Control plane"
        }
    }
}
