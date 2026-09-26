import AgentsKit
import SwiftUI

/// Settings ▸ Agents (048): the start-up sheet's list, for any time after it.
struct AgentsSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                ForEach(model.runtimes) { status in
                    RuntimeInstallRow(status: status)
                }
            } header: {
                Text("Agents on this Mac")
            } footer: {
                Text("Claude is installed into the app’s own folder, with nothing added to your PATH. "
                     + "The others use their makers’ own installers.")
            }
            .paperListRow()
        }
        .paperForm()
        .task { await model.refreshRuntimes() }
    }
}
