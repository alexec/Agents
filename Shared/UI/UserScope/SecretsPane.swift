import AgentsKitCore
import SwiftUI

/// Machines ▸ Secrets (#1760, #2157): the person's secrets, by name only, kept by the control
/// plane and sent to each machine of theirs. The window and the Remote draw it; the web page
/// draws the same in `Web/src/views/UserScope.tsx`.
struct SecretsPane: View {
    /// The control plane, or nil while it cannot be reached.
    let control: DaemonClient?
    let state: UserScopeState

    @State private var problem: String?
    @State private var isAdding = false
    @State private var replacing: DaemonAPI.UserSecretRow?
    @State private var removing: DaemonAPI.UserSecretRow?

    var body: some View {
        Form {
            if let problem = problem ?? state.problem {
                Section {
                    Text(problem).appText(.supporting).tinted(.failure)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .paperListRow()
            }
            if let left = state.left {
                Section {
                    Text(UserScopeWords.secretsLeft(left)).appText(.supporting).tinted(.attention)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("OK") { state.left = nil }
                }
                .paperListRow()
            }
            secretsSection
        }
        .paperForm()
        .task(id: control != nil) { await state.load(control) }
        .refreshable { await state.load(control) }
        .sheet(isPresented: $isAdding) {
            SecretSheet(name: nil) { name, value in await state.setSecret(name, value: value, on: control) }
                .paperSheet()
        }
        .sheet(item: $replacing) { row in
            SecretSheet(name: row.name) { name, value in await state.setSecret(name, value: value, on: control) }
                .paperSheet()
        }
        .confirmationDialog(removing.map { "Remove \($0.name)?" } ?? "",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible, presenting: removing) { row in
            Button("Remove", role: .destructive) {
                Task { problem = await state.removeSecret(row.name, on: control) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("It is taken out of secrets.env on every machine of yours.")
        }
    }

    private var secretsSection: some View {
        let rows: [DaemonAPI.UserSecretRow] = state.secrets?.secrets ?? []
        return Section {
            ForEach(rows) { row in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(row.name).appText(.code)
                        Spacer()
                        Menu {
                            Button("Replace…") { replacing = row }
                            Button("Remove…", role: .destructive) { removing = row }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .fixedSize()
                        .accessibilityLabel("\(row.name) actions")
                    }
                    Text(UserScopeWords.machines(row)).appText(.fine).foregroundStyle(.secondary)
                    if let left = UserScopeWords.leftOn(row) {
                        Text(left).appText(.fine).tinted(.attention)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if state.secrets?.sealing == false {
                Text(UserScopeWords.noSealing).appText(.supporting).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Button(UserScopeWords.addSecret) { isAdding = true }
                    .disabled(control == nil)
            }
        } footer: {
            Text(UserScopeWords.secretsFoot).appText(.fine).foregroundStyle(.secondary)
        }
        .paperListRow()
    }
}

/// Add a Secret… and Replace…: a name and a value. The value is never shown again.
private struct SecretSheet: View {
    /// The secret replaced, or nil for a new one.
    let name: String?
    let save: (String, String) async -> String?

    @Environment(\.dismiss) private var dismiss
    @State private var typedName = ""
    @State private var value = ""
    @State private var problem: String?
    @State private var saving = false

    private var chosen: String { name ?? typedName.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        Form {
            Section {
                if name == nil {
                    TextField("Name", text: $typedName, prompt: Text("GITHUB_TOKEN"))
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.characters)
                        #endif
                }
                SecureField("Value", text: $value)
            } header: {
                Text(name.map { "Replace \($0)" } ?? "Add a Secret")
            } footer: {
                Text(problem ?? UserScopeWords.nameHint).appText(.fine)
                    .tinted(problem == nil ? .none : .failure)
            }
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                Spacer()
                Button(name == nil ? "Add" : "Replace") {
                    Task {
                        saving = true
                        problem = await save(chosen, value)
                        saving = false
                        if problem == nil { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(saving || value.isEmpty || !UserScopeWords.isSecretName(chosen))
            }
            .rowButtons()
        }
        .paperForm()
        .frame(minWidth: 360)
        .onDisappear { value = "" }
    }
}
