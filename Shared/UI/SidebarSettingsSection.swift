import AgentsKitCore
import SwiftUI

/// Settings ▸ Sidebar (#846): a switch for each smart group, kept on this device only. The Mac's Settings window and the Remote's Settings screen draw
/// the same section; the web page keeps the same choice in its local storage.
struct SidebarSettingsSection: View {
    @AppStorage(SidebarSmartRow.offDefaultsKey, store: WindowDefaults.store) private var off = SidebarSmartRow.offAtFirst

    var body: some View {
        Section {
            ForEach(SidebarSmartRow.allCases, id: \.self) { row in
                Toggle(row.title, isOn: Binding(
                    get: { SidebarSmartRow.on(off: off).contains(row) },
                    set: { isOn in
                        var on = SidebarSmartRow.on(off: off)
                        if isOn { on.insert(row) } else { on.remove(row) }
                        off = SidebarSmartRow.off(on: on)
                    }))
            }
        } header: {
            Text("Smart groups")
        } footer: {
            Text("A group that is off is not shown. Its sessions go to the next group they fit, or under their project. "
                 + "With Needs You off, approvals are not listed in the sidebar.")
                .appText(.fine)
                .foregroundStyle(.secondary)
        }
        .paperListRow()
    }
}
