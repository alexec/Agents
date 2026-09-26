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
                Text(footer)
            }
            .paperListRow()
        }
        .paperForm()
        .task { await model.refreshRuntimes() }
    }

    /// Where Claude actually is: the person's own Node is used whenever there is one, so
    /// "installed into the app's own folder" is only true of the app's copy (or a promise
    /// about the install button).
    private var footer: String {
        let others = "The others use their makers’ own installers."
        guard let claude = model.runtimes.first(where: { $0.id == RuntimeCatalog.claude.id }) else {
            return others
        }
        if case .available(let path, _) = claude.availability {
            let tools = StoreLocations.default.tools.path
            return path.hasPrefix(tools + "/")
                ? "Claude is installed in the app’s own folder, with nothing added to your PATH. \(others)"
                : "Claude runs through your own Node (\(path)). \(others)"
        }
        return "Installing Claude puts it in the app’s own folder, with nothing added to your PATH. \(others)"
    }
}
