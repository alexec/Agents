import AgentsKitCore
import SwiftUI

/// Settings ▸ Machines (#1759): every machine, with its version (#1748) and what one too old
/// for the control plane is missing, as the window's Machines pane lists them. The control
/// plane's own version is under the list.
struct VersionsSettingsSection: View {
    @Environment(RemoteModel.self) private var model

    var body: some View {
        Section {
            if model.controlHosts.isEmpty {
                Text("No machines yet. Add one on the Mac, in Settings ▸ Machines.")
                    .appText(.supporting).foregroundStyle(.secondary)
            }
            ForEach(model.controlHosts) { host in
                VStack(alignment: .leading, spacing: 2) {
                    LabeledContent(host.name, value: versionWords(host))
                    if let status = model.controlStatus,
                       let missing = UpdateWords.missing(host, controlVersion: status.version) {
                        Text(missing).appText(.fine).tinted(.failure)
                    }
                }
            }
        } footer: {
            if let status = model.controlStatus {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(status.name): agents-control \(status.version)")
                    if let missing = UpdateWords.appMissing(status) {
                        Text(missing).tinted(.failure)
                    }
                }
                .appText(.fine)
            }
        }
        .paperListRow()
    }

    private func versionWords(_ host: DaemonAPI.ControlMachine) -> String {
        let version = UpdateWords.version(host)
        return host.state == "online" ? version : "\(UpdateWords.state(host)) · \(version)"
    }
}
