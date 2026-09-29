import AgentsKit
import SwiftUI

/// A runtime's Settings pane, selected from the Agent Runtimes rail heading.
struct AgentRuntimesSettingsView: View {
    @Environment(AppModel.self) private var model
    let runtimeID: String

    private var status: RuntimeStatus? {
        model.runtimes.first { $0.id == runtimeID }
    }

    var body: some View {
        Form {
            if let status {
                Section {
                    RuntimeInstallRow(status: status)
                    // A runtime whose only way in is a key from Settings (Gemini, 046) takes
                    // it here, beside where it is installed. The same key is lent to servers.
                    if CredentialKind.kinds(for: status.id).contains(where: \.isLentOnTheMac) {
                        CredentialRow(runtimeID: status.id, name: status.runtime.name)
                    }
                    // Cursor and Grok: permission mode lives here, not under the prompt (061).
                    if ClientPermissionSettings.supports(status.id) {
                        ClientPermissionModeRow(runtimeID: status.id, name: status.runtime.name)
                    }
                } footer: {
                    if let note = footer(for: status) { Text(note) }
                }
                .paperListRow()
                // Where it stands (065, US4): out, since when, when it is next checked, and
                // what is left of its plan. Shown here because this is where a runtime is
                // chosen from; never what decides whether a prompt is sent.
                if let row = model.runtimeAllowances?.rows.first(where: { $0.runtimeID == status.id }) {
                    Section("Allowance") {
                        RuntimeAllowanceRow(row: row, at: model.runtimeAllowances?.at ?? Date())
                    }
                    .paperListRow()
                }
            }
        }
        .paperForm()
        .task {
            await model.refreshRuntimes()
            await model.refreshClientPermissions()
            await model.refreshRuntimeAllowances()
        }
    }

    /// Claude's install note only: the person's own Node is used whenever there is one, so
    /// "installed into the app's own folder" is only true of the app's copy (or a promise
    /// about the install button). Other runtimes use their makers' own installers.
    private func footer(for status: RuntimeStatus) -> String? {
        guard status.id == RuntimeCatalog.claude.id else {
            return status.runtime.install == nil ? "Uses its maker’s own installer." : nil
        }
        if case .available(let path, _) = status.availability {
            let tools = StoreLocations.default.tools.path
            return path.hasPrefix(tools + "/")
                ? "Installed in the app’s own folder, with nothing added to your PATH."
                : "Runs through your own Node (\(path))."
        }
        return "Installing puts it in the app’s own folder, with nothing added to your PATH."
    }
}

/// A runtime's allowance, in `PoolWords` (065, contracts/runtime-state.md).
private struct RuntimeAllowanceRow: View {
    @Environment(AppModel.self) private var model
    let row: RuntimeAllowances.Row
    let at: Date

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(row.line(now: at))
                    .foregroundStyle(row.state.isOut ? StateTint.failure.style(or: .primary) : AnyShapeStyle(.primary))
                if row.unusable == nil, let reading = PoolWords.reading(row.state.reading, now: at) {
                    Text(reading)
                        .appText(.fine)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if row.state.isOut {
                // Asks nothing first: a wrong mark costs one refused turn (FR-023).
                Button("Mark available") {
                    Task { await model.markRuntimeAvailable(row.credentialKey) }
                }
                .controlSize(.small)
            }
        }
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
            Text("Always-approve").tag(ClientPermissionMode.alwaysApprove)
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
                guard ClientPermissionSettings.supports(runtimeID) else { return }
                let settings = model.clientPermissions.setting(mode, for: runtimeID)
                Task { await model.setClientPermissions(settings) }
            })
    }

    private var description: String {
        switch model.clientPermissions.mode(for: runtimeID) {
        case .default:
            return "Asks before \(name) does something that needs permission."
        case .alwaysApprove:
            return "Answers every permission request for you. Questions that are not permission still wait."
        }
    }
}
