import AgentsKit
import SwiftUI

/// Settings ▸ Agent Runtimes (048): the start-up sheet's list, for any time after it.
struct AgentRuntimesSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                ForEach(model.runtimes) { status in
                    RuntimeInstallRow(status: status)
                    // A runtime whose only way in is a key from Settings (Gemini, 046) takes
                    // it here, beside where it is installed; Servers shows the same key.
                    if CredentialKind.kinds(for: status.id).contains(where: \.isLentOnTheMac) {
                        CredentialRow(runtimeID: status.id, name: status.runtime.name)
                            .padding(.leading, 12)
                    }
                    // Cursor and Grok: permission mode lives here, not under the prompt (061).
                    if ClientPermissionSettings.supports(status.id) {
                        ClientPermissionModeRow(runtimeID: status.id, name: status.runtime.name)
                            .padding(.leading, 12)
                    }
                }
            } header: {
                Text("Agent runtimes on this Mac")
            } footer: {
                Text(footer)
            }
            .paperListRow()
        }
        .paperForm()
        .task {
            await model.refreshRuntimes()
            await model.refreshClientPermissions()
        }
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

/// One permission-mode picker for Cursor or Grok (061). Present even when that runtime
/// is not installed; it takes effect the next time an agent on it asks.
private struct ClientPermissionModeRow: View {
    @Environment(AppModel.self) private var model
    let runtimeID: String
    let name: String

    var body: some View {
        Picker("\(name) permission mode", selection: binding) {
            Text("Default").tag(ClientPermissionMode.default)
            Text("Auto-review").tag(ClientPermissionMode.autoReview)
        }
        Text(description)
            .appText(.supporting)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var binding: Binding<ClientPermissionMode> {
        Binding(
            get: { model.clientPermissions.mode(for: runtimeID) },
            set: { mode in
                var settings = model.clientPermissions
                switch runtimeID {
                case RuntimeCatalog.cursor.id: settings.cursor = mode
                case RuntimeCatalog.grok.id: settings.grok = mode
                default: return
                }
                Task { await model.setClientPermissions(settings) }
            })
    }

    private var description: String {
        switch model.clientPermissions.mode(for: runtimeID) {
        case .default:
            return "Asks before \(name) does something that needs permission."
        case .autoReview:
            return "Allows ordinary work inside the project; asks before anything that leaves it, publishes, or needs extra privilege."
        }
    }
}
