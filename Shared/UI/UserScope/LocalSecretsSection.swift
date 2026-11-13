import AgentsKitCore
import SwiftUI

/// Where Settings ▸ You ▸ Secrets ▸ On This Machine reads and writes (#5122): the window's model
/// and the Remote's, each through the Mac's host it reaches. Its Ask before use toggle shows when
/// the host keeps the flag (`sessionHostAsksBeforeUse`).
@MainActor
protocol LocalSecretsSource: SessionSecretsSource {
    /// Nil from a host too old to know the method.
    func localSecrets() async -> LocalSecrets?
    func setLocalSecretAsksBeforeUse(_ secret: LocalSecret, _ on: Bool) async -> Result<LocalSecrets?, Error>
}

/// Settings ▸ You ▸ Secrets ▸ On This Machine (#5122): the secrets the Mac's host keeps for
/// itself, which agents saved there (`ask_secret`, `capture_secret`, `generate_secret`), each
/// with an Ask before use toggle (#4016). Without it a person could not see them, nor turn the
/// flag off so a script can read one. Left out when there are none. The window and the Remote
/// draw it; the web page draws the same in `Web/src/views/settings/LocalSecrets.tsx`.
struct LocalSecretsSection<Source: LocalSecretsSource>: View {
    let model: Source
    @State private var list: LocalSecrets?
    @State private var loaded = false
    @State private var problem: String?

    var body: some View {
        // Drawn while it loads, so its task runs (an empty view runs none); then left out when there
        // are none, or when the host is too old to list them.
        if !loaded || !(list?.secrets.isEmpty ?? true) {
            Section {
                if let list {
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
                        }
                        #else
                        // A phone's switch is too wide to share the name's line: it goes under it.
                        VStack(alignment: .leading, spacing: 6) {
                            label(secret)
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
                } else {
                    ProgressView().controlSize(.small)
                }
            } header: {
                Text(LocalSecretWords.header)
            } footer: {
                Text(LocalSecretWords.footer).appText(.fine).foregroundStyle(.secondary)
            }
            .paperListRow()
            .task {
                list = await model.localSecrets()
                loaded = true
            }
        }
    }

    private func label(_ secret: LocalSecret) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(secret.name).appText(.code)
            Text(UserScopeWords.about(secret.description)).appText(.fine).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SecretInfoLine(parts: SecretInfoWords.line(secret))
            Text("⚠ " + LocalSecretWords.notBackedUp).appText(.fine).tinted(.attention)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// A row's Ask before use: the host seals it again with the other flag, then the list is read again.
    private func asksBeforeUse(_ secret: LocalSecret) -> Binding<Bool> {
        Binding(get: { secret.asksBeforeUse }, set: { on in
            Task {
                switch await model.setLocalSecretAsksBeforeUse(secret, on) {
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
