import AgentsKitCore
import SwiftUI

/// Settings ▸ Secrets ▸ For One Session (#3548): this Mac's secrets for one session only,
/// each with the session it belongs to and a Remove, and Add for a Session…. Only that
/// session's agent can use one, and this Mac's host deletes it when the session is archived.
/// Each has an Ask before use toggle (#4016). The web page draws the same in
/// `Web/src/views/settings/SessionSecrets.tsx`.
struct SessionSecretsSection: View {
    @Environment(AppModel.self) private var model
    @State private var list: SessionSecrets?
    @State private var loaded = false
    @State private var isAdding = false
    @State private var removing: SessionSecret?
    @State private var problem: String?

    var body: some View {
        // A host too old to keep them: the section stays out.
        if !loaded || list != nil {
            Section {
                if let list {
                    if list.secrets.isEmpty {
                        Text(SessionSecretWords.none).foregroundStyle(.secondary)
                    }
                    ForEach(list.secrets) { secret in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(secret.name).appText(.code)
                                Text(secret.title).appText(.fine).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if model.macHostAsksBeforeUse {
                                Toggle(AskBeforeUseWords.toggle, isOn: asksBeforeUse(secret))
                                    .toggleStyle(.checkbox)
                                    .appText(.supporting)
                                    .help(AskBeforeUseWords.hint(secret.asksBeforeUse))
                            }
                            Button("Remove…", role: .destructive) { removing = secret }
                                .accessibilityLabel("Remove \(secret.name) from \(secret.title)")
                        }
                    }
                    if let problem {
                        Text(problem).appText(.fine).tinted(.failure)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Button(SessionSecretWords.add) { isAdding = true }
                } else {
                    ProgressView().controlSize(.small)
                }
            } header: {
                Text(SessionSecretWords.header)
            } footer: {
                Text(SessionSecretWords.footer).appText(.fine).foregroundStyle(.secondary)
            }
            .paperListRow()
            .task {
                list = await model.sessionSecrets()
                loaded = true
            }
            .sheet(isPresented: $isAdding) {
                SessionSecretSheet(sessions: model.sessionsForSecrets, offersAsk: model.macHostAsksBeforeUse) { request in
                    switch await model.setSessionSecret(request) {
                    case .success(let after):
                        list = after
                        return nil
                    case .failure(let error):
                        return UserScopeWords.refusal(error)
                    }
                }
                .paperSheet()
            }
            .confirmationDialog(removing.map(SessionSecretWords.removeQuestion) ?? "",
                                isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                                titleVisibility: .visible, presenting: removing) { secret in
                Button("Remove", role: .destructive) {
                    Task { if let after = await model.removeSessionSecret(secret) { list = after } }
                }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text(SessionSecretWords.removeMessage)
            }
        }
    }

    /// A row's Ask before use: the host seals it or puts it back, then the list is read again.
    private func asksBeforeUse(_ secret: SessionSecret) -> Binding<Bool> {
        Binding(get: { secret.asksBeforeUse }, set: { on in
            Task {
                switch await model.setSessionSecretAsksBeforeUse(secret, on) {
                case .success(let after):
                    problem = nil
                    if let after { list = after }
                case .failure(let error):
                    problem = UserScopeWords.refusal(error)
                }
            }
        })
    }
}

/// Add for a Session…: which session, a name and a value. The value is never shown again.
private struct SessionSecretSheet: View {
    let sessions: [Agent]
    /// The host keeps Ask before use (#4016); a person's secret starts off.
    let offersAsk: Bool
    let save: (SessionSecretSetRequest) async -> String?

    @Environment(\.dismiss) private var dismiss
    @State private var session: UUID?
    @State private var name = ""
    @State private var value = ""
    @State private var askBeforeUse = false
    @State private var problem: String?
    @State private var saving = false

    private var chosen: String { name.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        Form {
            Section {
                if sessions.isEmpty {
                    Text(SessionSecretWords.noSessions).foregroundStyle(.secondary)
                } else {
                    Picker(SessionSecretWords.session, selection: $session) {
                        ForEach(sessions) { agent in
                            Text(agent.title ?? "Untitled session").tag(Optional(agent.id))
                        }
                    }
                }
                TextField("Name", text: $name, prompt: Text("SHOP_PASSWORD"))
                    .autocorrectionDisabled()
                SecureField("Value", text: $value)
                if offersAsk {
                    AskBeforeUseToggle(isOn: $askBeforeUse)
                }
            } header: {
                Text(SessionSecretWords.sheetTitle)
            } footer: {
                Text(problem ?? SessionSecretWords.footer).appText(.fine)
                    .tinted(problem == nil ? .none : .failure)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                Spacer()
                Button("Add") {
                    guard let session else { return }
                    Task {
                        saving = true
                        problem = await save(SessionSecretSetRequest(agentID: session, name: chosen, value: value,
                                                                     needsApproval: offersAsk && askBeforeUse ? true : nil))
                        saving = false
                        if problem == nil { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(saving || session == nil || value.isEmpty || !UserScopeWords.isSecretName(chosen))
            }
            .rowButtons()
        }
        .paperForm()
        .frame(minWidth: 400)
        .onAppear { session = session ?? sessions.first?.id }
        .onDisappear { value = "" }
    }
}
