import AgentsKitCore
import SwiftUI

/// Settings ▸ Versions (#1748): the control plane's version and each host's, as the window's
/// Control plane pane says them, and what a host too old for the control plane is missing.
/// Nothing when this device is not a control plane's client.
struct VersionsSettingsSection: View {
    @Environment(RemoteModel.self) private var model

    var body: some View {
        if let status = model.controlStatus {
            Section("Versions") {
                LabeledContent(status.name, value: "agents-control \(status.version)")
                if let missing = UpdateWords.appMissing(status) {
                    Text(missing).appText(.fine).tinted(.failure)
                }
                ForEach(model.controlHosts) { host in
                    VStack(alignment: .leading, spacing: 2) {
                        LabeledContent(host.name, value: versionWords(host))
                        if let missing = UpdateWords.missing(host, controlVersion: status.version) {
                            Text(missing).appText(.fine).tinted(.failure)
                        }
                    }
                }
            }
        }
    }

    private func versionWords(_ host: DaemonAPI.ControlHost) -> String {
        let version = UpdateWords.version(host)
        return host.state == "online" ? version : "\(UpdateWords.state(host)) · \(version)"
    }
}
