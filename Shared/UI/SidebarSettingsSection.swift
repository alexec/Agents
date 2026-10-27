import AgentsKitCore
import SwiftUI

/// Settings ▸ You ▸ Sidebar (#846, #2079): a switch for each smart group, and whether agents
/// may archive the chats the person starts (#1802).
/// All are kept on the Mac's host, so every
/// client shows the same (#1033). The Mac's Settings window and the Remote's Settings screen
/// draw the same section; the web page has the same two sections under You.
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
            Text("A group that is off is not shown. Its sessions go to the next group they fit, or under their folder. "
                 + "With Needs You off, approvals are not listed in the sidebar. The same on every client of yours.")
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
                 + "Archived chats come back with Unarchive. "
                 // Each host reads its own preferences (#1872): the docs' sentence.
                 + "Another machine does not read this switch, so a chat in a folder on another machine may still archive itself.")
                .appText(.fine)
                .foregroundStyle(.secondary)
        }
        .paperListRow()
    }
}
