import AgentsKitCore
import SwiftUI

/// Settings ▸ You ▸ Machines: the versions of the control plane and its machines (#1748), git
/// access, and the Mac's backups, as the window's Settings ▸ Machines ▸ This Mac draws them
/// (#1810), each server's (#1815), and what is the same on all your machines (#2157).
struct MachinesSettingsRow: View {
    @Environment(RemoteModel.self) private var model

    var body: some View {
        SettingsPageLink("Machines", systemImage: "desktopcomputer") {
            if !model.needsPairing { AddMachineSection() }
            VersionsSettingsSection()
            GitAccessSettingsSection()
            // The folder is the Mac's disk, so it is chosen on the Mac.
            if let backups = model.work.backupState {
                BackupsSection(state: backups, configure: model.configureBackups, make: model.makeBackup,
                               restore: model.restoreBackup)
            }
            ServerBackupsSettingsSection()
            if !model.needsPairing {
                UserPartsSection(control: model.controlPlane, state: model.userScope)
            }
        }
        .task { await model.refreshBackupState() }
    }
}

/// Add a Machine… (#2131): a provider, a server or another Mac, as the window's Machines has it.
private struct AddMachineSection: View {
    @State private var adding = false

    var body: some View {
        Section {
            Button(AddMachine.Words.menuItem) { adding = true }
        } footer: {
            Text(AddMachine.Words.machinesFoot)
        }
        .sheet(isPresented: $adding) { AddMachineSheet() }
    }
}
