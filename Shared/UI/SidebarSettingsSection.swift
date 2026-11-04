import AgentsKitCore
import SwiftUI

/// Settings ▸ You ▸ Sidebar (#846, #2079): a switch for each smart group. Whether agents may
/// archive the chats the person starts (#1802) is a rule of Agents ▸ Policy (#2957, FR-023).
/// All are kept on the Mac's host, so every
/// client shows the same (#1033). The Mac's Settings window and the Remote's Settings screen
/// draw the same section; the web page has the same two sections under You.
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
            Text("A group that is off is not shown. Its sessions go to the next group they fit, or under their folder. "
                 + "With Needs You off, approvals are not listed in the sidebar. The same on every client of yours.")
                .appText(.fine)
                .foregroundStyle(.secondary)
        }
        .paperListRow()
    }
}
