import AgentsKitCore
import SwiftUI

/// Settings ▸ Machines: git access, as the window's Settings ▸ Machines ▸ This Mac draws it. Adding
/// a machine, the versions and the backups are Mac + web (#2796, #2798): a line says where they are.
struct MachinesSettingsRow: View {
    var body: some View {
        SettingsPageLink("Machines", systemImage: "desktopcomputer") {
            GitAccessSettingsSection()
            Section { OnMacOrWeb(page: "settings") }
                .paperListRow()
        }
    }
}
