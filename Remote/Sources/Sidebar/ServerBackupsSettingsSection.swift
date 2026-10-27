import AgentsKitCore
import SwiftUI

/// Settings ▸ Machines' Backups (#1815): a row for each server on the control plane that
/// answers now, opening its backups, as the window opens them from the host's menu in
/// Settings ▸ Machines. The home Mac's are the Backups section above; a relay
/// runs no agents, so it has none. Nothing when no server can be asked.
struct ServerBackupsSettingsSection: View {
    @Environment(RemoteModel.self) private var model

    var body: some View {
        let servers = model.controlHosts.filter { host in
            host.id != model.controlHome && host.relay == nil && model.hostClient(host.id) != nil
                && model.host(host.id, has: Capability.backups1)
        }
        if !servers.isEmpty {
            Section("Machines' Backups") {
                ForEach(servers) { host in
                    if let client = model.hostClient(host.id) {
                        NavigationLink(host.name) {
                            HostBackupsView(client: client, hostName: host.name)
                                .navigationTitle(host.name)
                        }
                    }
                }
            }
        }
    }
}
