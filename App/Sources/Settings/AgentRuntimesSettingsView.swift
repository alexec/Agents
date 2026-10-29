import AgentsKitCore
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
                    // A runtime the organisation does not allow here: shown, with why (#998).
                    if let mark = status.setBy { OrgPolicyLine(mark: mark) }
                    RuntimeInstallRow(status: status)
                    // A runtime whose only way in is a key from Settings (Gemini, 046) takes
                    // it here, beside where it is installed. The same key is lent to servers.
                    if CredentialKind.kinds(for: status.id).contains(where: \.isLentOnTheMac) {
                        CredentialRow(runtimeID: status.id, name: status.runtime.name)
                    }
                } footer: {
                    // Where its allowance stands is on the Runtimes page under Activity, not
                    // here (065). This is where a runtime is changed; that is where its state
                    // is read.
                    VStack(alignment: .leading, spacing: 4) {
                        if let note = footer(for: status) { Text(note) }
                        Text("Where its allowance stands is on the Runtimes page, under Activity.")
                    }
                }
                .paperListRow()
                // Its command sandbox (064): a default every agent on it follows, or why
                // the app has no say.
                Section(LevelWords.sandboxField) {
                    SandboxDefaultRow(runtimeID: status.id, name: status.runtime.name)
                }
                .paperListRow()
                // The answer to permission requests every new agent on it starts with; an
                // agent can have its own under the prompt (#2658, FR-019).
                if ClientPermissionSettings.supports(status.id) {
                    Section(LevelWords.requestsField) {
                        Picker(LevelWords.requestsField, selection: Binding(
                            get: { model.clientPermissions.mode(for: status.id) },
                            set: { mode in
                                let settings = model.clientPermissions.setting(mode, for: status.id)
                                Task { await model.setClientPermissions(settings) }
                            })) {
                            ForEach([ClientPermissionMode.default, .alwaysApprove], id: \.self) { mode in
                                Text(LevelWords.requests(mode)).tag(mode)
                            }
                        }
                        .disabled(model.clientPermissions.setBy != nil)
                        if let mark = model.clientPermissions.setBy { OrgPolicyLine(mark: mark) }
                        Text("New \(status.runtime.name) agents, workflows and server folders follow this unless one is set otherwise under the prompt.")
                            .appText(.fine)
                            .foregroundStyle(.secondary)
                    }
                    .paperListRow()
                }
                // The person's own pass-through names, a name the policy does not allow dimmed (#998).
                let names = model.passThrough.names(for: status.id)
                if !names.isEmpty {
                    Section(OrgPolicyWords.passThroughTitle) { PassThroughRows(names: names) }
                        .paperListRow()
                }
            }
        }
        .paperForm()
        .task {
            await model.refreshRuntimes()
            await model.refreshClientPermissions()
            await model.refreshSandboxSettings()
            await model.refreshPassThrough()
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
                : "Runs through your own Node."
        }
        return "Installing puts it in the app’s own folder, with nothing added to your PATH."
    }
}

/// A runtime's command sandbox default (064, FR-001, FR-014). A runtime the app cannot reach
/// shows its state and the reason instead of a control.
private struct SandboxDefaultRow: View {
    @Environment(AppModel.self) private var model
    let runtimeID: String
    let name: String

    var body: some View {
        let choices = SandboxCatalog.choices(for: runtimeID)
        let entry = SandboxCatalog.entry(for: runtimeID)
        if choices.isEmpty {
            LabeledContent("Default", value: stateWords(entry))
            // No sandbox the app can vouch for, so the organisation's rule refuses it (#998).
            if let mark = model.sandboxSettings.setBy { OrgPolicyLine(mark: mark) }
            if let why = entry?.why { supporting(why) }
        } else {
            Picker("Default", selection: binding) {
                ForEach(choices, id: \.self) { choice in
                    // While the organisation requires the sandbox, only On is in force (#998): the rest shown, not chosen.
                    Text(SandboxWords.choice(choice, runtimeID: runtimeID)).tag(choice)
                        .disabled(isRefused(choice))
                }
            }
            if let mark = model.sandboxSettings.setBy { OrgPolicyLine(mark: mark) }
            supporting(SandboxWords.explanation(model.sandboxSettings.choice(for: runtimeID),
                                                runtimeID: runtimeID, name: name))
            if let why = entry?.why { supporting(why) }
            supporting("New \(name) agents follow this unless one is set otherwise; a change applies from each one’s next turn.")
        }
    }

    private func isRefused(_ choice: SandboxChoice) -> Bool {
        model.sandboxSettings.setBy != nil && choice != .on
    }

    private func stateWords(_ entry: SandboxCatalog.Entry?) -> String {
        if case .fixed(let state) = entry?.route {
            return LevelWords.sandbox(state == .none ? .off : .runtime)
        }
        return LevelWords.sandbox(.runtime)
    }

    private func supporting(_ text: String) -> some View {
        Text(text)
            .appText(.supporting)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var binding: Binding<SandboxChoice> {
        Binding(
            get: { model.sandboxSettings.choice(for: runtimeID) },
            set: { choice in Task { await model.setSandboxDefault(choice, for: runtimeID) } })
    }
}
