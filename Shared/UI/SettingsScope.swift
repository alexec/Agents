import AgentsKitCore

/// Settings' groups by subject (#2157, was by scope #1759; spec 736 FR-022), the same on
/// the window's rail, the Remote's Settings and the page's: this app, what agents may do
/// (#2957), the machines that run agents, and what the control plane keeps (the person's
/// account first). The window's panes
/// for each are `SettingsScope.panes`; a pane added later goes there.
enum SettingsScope: CaseIterable {
    case thisApp, agents, machines, controlPlane

    var title: String {
        switch self {
        case .thisApp: "This app"
        case .agents: PolicyLayersWords.groupTitle
        case .machines: "Machines"
        case .controlPlane: "Control plane"
        }
    }
}
