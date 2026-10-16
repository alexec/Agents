import AgentsKitCore
import SwiftUI

/// Settings ▸ Sidebar (#846): a switch for each smart group, kept on this device only. The Mac's Settings window and the Remote's Settings screen draw
/// the same section; the web page keeps the same choice in its local storage.
struct SidebarSettingsSection: View {
    @AppStorage(SidebarSmartRow.offDefaultsKey, store: WindowDefaults.store) private var off = SidebarSmartRow.offAtFirst
    /// The main window's style (#1090), the same on every client (#1033).
    @AppStorage(HomeWindow.defaultsKey, store: WindowDefaults.store) private var home = HomeWindow.initial

    var body: some View {
        Section {
            Picker("Home window", selection: $home) {
                ForEach(HomeWindow.allCases, id: \.self) { Text($0.title).tag($0) }
            }
        } footer: {
            Text("All projects is the sidebar of every project. Launcher is a small window of project cards, "
                 + "with each project in a window of its own.")
                .appText(.fine)
                .foregroundStyle(.secondary)
        }
        .paperListRow()
        Section {
            ForEach(SidebarSmartRow.allCases, id: \.self) { row in
                Toggle(row.title, isOn: Binding(
                    get: { SidebarSmartRow.on(off: off).contains(row) },
                    set: { isOn in
                        var on = SidebarSmartRow.on(off: off)
                        if isOn { on.insert(row) } else { on.remove(row) }
                        off = SidebarSmartRow.off(on: on)
                    }))
                    // The launcher has no smart groups (Alex, #1090): kept as they are, greyed.
                    .disabled(home == .launcher)
            }
        } header: {
            Text("Smart groups")
        } footer: {
            Text(home == .launcher
                 ? "The launcher has no smart groups. Choose All projects to use them."
                 : "A group that is off is not shown. Its sessions go to the next group they fit, or under their project. "
                    + "With Needs You off, approvals are not listed in the sidebar.")
                .appText(.fine)
                .foregroundStyle(.secondary)
        }
        .paperListRow()
    }
}
