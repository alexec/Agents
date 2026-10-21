import AgentsKitCore
import SwiftUI

/// Settings ▸ You ▸ Machines: the versions of the control plane and its machines (#1748), git
/// access, and the Mac's backups, as the window's Settings ▸ Machines ▸ This Mac draws them
/// (#1810), and each server's (#1815).
struct MachinesSettingsRow: View {
    @Environment(RemoteModel.self) private var model

    var body: some View {
        SettingsPageLink("Machines", systemImage: "desktopcomputer") {
            VersionsSettingsSection()
            GitAccessSettingsSection()
            // The folder is the Mac's disk, so it is chosen on the Mac.
            if let backups = model.work.backupState {
                BackupsSection(state: backups, configure: model.configureBackups, make: model.makeBackup,
                               restore: model.restoreBackup)
            }
            ServerBackupsSettingsSection()
        }
        .task { await model.refreshBackupState() }
    }
}
