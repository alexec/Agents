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
                    // Where its allowance stands is on the Runtimes page under Activity, not
                    // here (065). This is where a runtime is changed; that is where its state
                    // is read.
                    VStack(alignment: .leading, spacing: 4) {
                        if let note = footer(for: status) { Text(note) }
                        Text("Where its allowance stands is on the Runtimes page, under Activity.")
                    }
                }
                .paperListRow()
                // Assess it (#47): an agent on it works through every group of the app's
                // tools, and the daemon scores what it did from its own record.
                Section("Assessment") {
                    AssessRuntimeRow(runtimeID: status.id, name: status.runtime.name)
                }
                .paperListRow()
                // Its command sandbox (064): a default every agent on it follows, or why
                // the app has no say.
                Section("Command sandbox") {
                    SandboxDefaultRow(runtimeID: status.id, name: status.runtime.name)
                }
                .paperListRow()
            }
        }
        .paperForm()
        .task {
            await model.refreshRuntimes()
            await model.refreshClientPermissions()
            await model.refreshSandboxSettings()
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
            if let why = entry?.why { supporting(why) }
        } else {
            Picker("Default", selection: binding) {
                ForEach(choices, id: \.self) { choice in
                    Text(SandboxWords.choice(choice, runtimeID: runtimeID)).tag(choice)
                }
            }
            supporting(SandboxWords.explanation(model.sandboxSettings.choice(for: runtimeID),
                                                runtimeID: runtimeID, name: name))
            if let why = entry?.why { supporting(why) }
            supporting("New \(name) agents follow this unless one is set otherwise; a change applies from each one’s next turn.")
        }
    }

    private func stateWords(_ entry: SandboxCatalog.Entry?) -> String {
        if case .fixed(let state) = entry?.route {
            return state == .none ? "No sandbox" : "Runtime controlled"
        }
        return "Runtime controlled"
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

/// "Assess…" (#47): pick a project on this Mac, and an agent on this runtime is started there
/// with the assessment's steps, on the cheapest model the runtime has offered. Its report
/// goes to `.agents/reviews/runtimes/` in that project, and the app's own score into its
/// conversation when it ends.
private struct AssessRuntimeRow: View {
    @Environment(AppModel.self) private var model
    let runtimeID: String
    let name: String
    @State private var refusal: String?
    @State private var starting = false

    private var projects: [DaemonAPI.ProjectSummary] {
        model.projects.filter { $0.host == .mac && $0.exists && $0.project.archivedAt == nil }
    }

    var body: some View {
        LabeledContent {
            Menu("Assess…") {
                ForEach(projects) { summary in
                    Button(summary.name) { assess(in: summary.project.folder) }
                }
            }
            .menuStyle(.button)
            .fixedSize()
            .disabled(projects.isEmpty || starting)
        } label: {
            Text("Check \(name) with the app’s tools")
        }
        Text("Starts an agent on \(name) that works through the app’s tools — ending a turn, questions, "
             + "files, helpers, leases, events, the Dashboard and workflows — and writes a report. The app "
             + "scores it from its own record. It asks you two short questions.")
            .appText(.supporting)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        if let refusal {
            Text(refusal)
                .appText(.supporting)
                .foregroundStyle(StateTint.failure.style(or: .primary))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func assess(in folder: URL) {
        starting = true
        refusal = nil
        Task {
            refusal = await model.assessRuntime(runtimeID, in: folder)
            starting = false
        }
    }
}
