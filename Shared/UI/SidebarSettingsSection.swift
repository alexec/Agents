import AgentsKitCore
import SwiftUI

/// Settings ▸ Sidebar (#846): a switch for each smart group, kept on this device only, and
/// whether agents may archive the chats the person starts (#1802), kept on the Mac's host. The Mac's Settings window and the Remote's Settings screen draw
/// the same section; the web page keeps the same choice in its local storage.
struct SidebarSettingsSection: View {
    @AppStorage(SidebarSmartRow.offDefaultsKey, store: WindowDefaults.store) private var off = SidebarSmartRow.offAtFirst
    /// Kept on the Mac's host with the other display choices, so every device shows the
    /// same; the host reads it when a chat you started ends (#1802).
    @AppStorage(DisplayPreference.agentsMayArchiveMyChats, store: WindowDefaults.store)
    private var mayArchive = DisplayPreference.agentsMayArchiveMyChatsDefault

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

        Section {
            Toggle("Agents may archive the chats I start", isOn: $mayArchive)
        } header: {
            Text("Finished chats")
        } footer: {
            Text("On, a chat you started that asks to be archived is archived when its turn ends Complete or "
                 + "Nothing to do, unless it showed you a file. Off, it waits for you to approve it. "
                 + "Archived chats come back with Unarchive.")
                .appText(.fine)
                .foregroundStyle(.secondary)
        }
        .paperListRow()
    }
}
