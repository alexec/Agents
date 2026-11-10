import AgentsKitCore
import SwiftUI

/// Where Settings ▸ You ▸ Secrets ▸ For One Session reads and writes (#3548): the window's model
/// and the Remote's, each through the Mac's host it reaches (#4032).
@MainActor
protocol SessionSecretsSource: AnyObject {
    /// Nil from a host too old to know the method.
    func sessionSecrets() async -> SessionSecrets?
    func setSessionSecret(_ request: SessionSecretSetRequest) async -> Result<SessionSecrets, Error>
    func setSessionSecretAsksBeforeUse(_ secret: SessionSecret, _ on: Bool) async -> Result<SessionSecrets?, Error>
    func removeSessionSecret(_ secret: SessionSecret) async -> SessionSecrets?
    /// The sessions on that host that can take a secret for one session: not archived, latest first.
    var sessionsForSecrets: [Agent] { get }
    /// Whether that host keeps Ask before use (#4014): it offers the toggle (#4016).
    var sessionHostAsksBeforeUse: Bool { get }
}

/// Settings ▸ Secrets ▸ For One Session (#3548): the Mac's secrets for one session only,
/// each with the session it belongs to and a Remove, and Add for a Session…. Only that
/// session's agent can use one, and the Mac's host deletes it when the session is archived.
/// Each has an Ask before use toggle (#4016). The window and the Remote (#4032) draw it; the web
/// page draws the same in `Web/src/views/settings/SessionSecrets.tsx`.
struct SessionSecretsSection<Source: SessionSecretsSource>: View {
    let model: Source
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
                        #if os(macOS)
                        HStack {
                            label(secret)
                            Spacer()
                            if model.sessionHostAsksBeforeUse {
                                Toggle(AskBeforeUseWords.toggle, isOn: asksBeforeUse(secret))
                                    .toggleStyle(.checkbox)
                                    .appText(.supporting)
                                    .help(AskBeforeUseWords.hint(secret.asksBeforeUse))
                            }
                            remove(secret)
                        }
                        #else
                        // A phone's switch is too wide to share the name's line: it goes under it.
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                label(secret)
                                Spacer()
                                remove(secret)
                            }
                            if model.sessionHostAsksBeforeUse {
                                Toggle(AskBeforeUseWords.toggle, isOn: asksBeforeUse(secret))
                                    .appText(.supporting)
                            }
                        }
                        #endif
                    }
                    if let problem {
                        Text(problem).appText(.fine).tinted(.failure)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    // The sheet and the question hang on one row: on a Section, iOS gives each row its own,
                    // and the Remote's Settings closed at Add for a Session… (#4032).
                    Button(SessionSecretWords.add) { isAdding = true }
                        .sheet(isPresented: $isAdding) {
                            SessionSecretSheet(sessions: model.sessionsForSecrets, offersAsk: model.sessionHostAsksBeforeUse) { request in
                                switch await model.setSessionSecret(request) {
                                case .success(let after):
                                    self.list = after
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
                                Task { if let after = await model.removeSessionSecret(secret) { self.list = after } }
                            }
                            Button("Cancel", role: .cancel) {}
                        } message: { _ in
                            Text(SessionSecretWords.removeMessage)
                        }
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
        }
    }

    private func label(_ secret: SessionSecret) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(secret.name).appText(.code)
                Text(SecretInfoWords.hint(secret.hint)).appText(.code).foregroundStyle(.secondary)
                    .accessibilityLabel(secret.hint.map { "Ends in \($0)" } ?? "Value hidden")
            }
            Text(UserScopeWords.about(secret.description)).appText(.fine).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SecretInfoLine(parts: SecretInfoWords.line(secret))
            Text("⚠ " + SecretInfoWords.sessionNotBackedUp).appText(.fine).tinted(.attention)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func remove(_ secret: SessionSecret) -> some View {
        Button("Remove…", role: .destructive) { removing = secret }
            .accessibilityLabel("Remove \(secret.name) from \(secret.title)")
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
    /// The host keeps Ask before use (#4016); a new secret starts on (#4162).
    let offersAsk: Bool
    let save: (SessionSecretSetRequest) async -> String?

    @Environment(\.dismiss) private var dismiss
    @State private var session: UUID?
    @State private var name = ""
    @State private var value = ""
    @State private var about = ""
    @State private var askBeforeUse = true
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
                    #if os(iOS)
                    .textInputAutocapitalization(.characters)
                    #endif
                SecureField("Value", text: $value)
                SecretDescriptionField(text: $about)
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
                                                                     needsApproval: offersAsk && askBeforeUse ? true : nil,
                                                                     description: UserScopeWords.description(about)))
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
        #if os(macOS)
        .frame(minWidth: 400)
        #endif
        .onAppear { session = session ?? sessions.first?.id }
        .onDisappear { value = "" }
    }
}
