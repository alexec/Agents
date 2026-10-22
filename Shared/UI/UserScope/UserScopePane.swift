import AgentsKitCore
import SwiftUI

/// You ▸ On Every Machine (#1760, spec 736 US4): the person's secrets and the settings that
/// are the same on every machine of theirs, kept by the control plane. The window and the
/// Remote draw it; the web page draws the same in `Web/src/views/UserScope.tsx`.
struct UserScopePane: View {
    /// The control plane, or nil while it cannot be reached.
    let control: DaemonClient?
    let state: UserScopeState
    /// Use This Mac's: takes a part from this machine and sets it at the user scope, nil
    /// once done, else why not. Nil where there is no machine of one's own to take it from
    /// (the Remote).
    var takeHere: (name: String, take: (DaemonAPI.UserSettingsPartName) async -> String?)?

    @State private var problem: String?
    @State private var isAdding = false
    @State private var replacing: DaemonAPI.UserSecretRow?
    @State private var removing: DaemonAPI.UserSecretRow?
    @State private var giving: DaemonAPI.UserSettingsPartName?
    @State private var busy: DaemonAPI.UserSettingsPartName?

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
            partsSection
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
        .confirmationDialog(giving.map { "\(UserScopeWords.partTitle($0)): each machine its own?" } ?? "",
                            isPresented: Binding(get: { giving != nil }, set: { if !$0 { giving = nil } }),
                            titleVisibility: .visible, presenting: giving) { part in
            Button(UserScopeWords.stop) { Task { problem = await state.set(part, to: .null, on: control) } }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Each machine keeps what it has now, and changes it in its own pane.")
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
        } header: {
            Text(UserScopeWords.secretsHeading)
        } footer: {
            Text(UserScopeWords.secretsFoot).appText(.fine).foregroundStyle(.secondary)
        }
        .paperListRow()
    }

    private var partsSection: some View {
        Section {
            ForEach(DaemonAPI.UserSettingsPartName.allCases, id: \.self) { part in
                let follows = state.follows(part)
                VStack(alignment: .leading, spacing: 4) {
                    Text(UserScopeWords.partTitle(part)).appText(.reading)
                    Text(UserScopeWords.partDetail(part)).appText(.fine).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(UserScopeWords.partState(state.settings?[part], updated: state.settings?.updated))
                        .appText(.fine)
                    HStack {
                        if let takeHere {
                            Button(UserScopeWords.useHere(takeHere.name)) {
                                Task {
                                    busy = part
                                    problem = await takeHere.take(part)
                                    busy = nil
                                }
                            }
                            .disabled(control == nil || busy != nil)
                            .accessibilityIdentifier("useHere-\(part.rawValue)")
                        }
                        if follows {
                            Button(UserScopeWords.stop) { giving = part }
                                .disabled(control == nil || busy != nil)
                                .accessibilityIdentifier("stop-\(part.rawValue)")
                        }
                        if busy == part { ProgressView().controlSize(.small) }
                    }
                    .rowButtons()
                }
            }
        } header: {
            Text(UserScopeWords.partsHeading)
        } footer: {
            Text(takeHere == nil ? UserScopeWords.partsFoot + " " + UserScopeWords.partsFootNoTake : UserScopeWords.partsFoot)
                .appText(.fine).foregroundStyle(.secondary)
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
