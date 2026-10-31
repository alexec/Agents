import AgentsKitCore
import SwiftUI

/// Connect Email (#1780): the Connect GitLab sheet with only its fields. The IMAP server, the
/// user and an app password go to the host, which signs in once to check them and keeps the
/// password. The password stays in this sheet's state only, and is cleared once it is sent.
struct ConnectEmailSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var host: MachineRef
    var onConnected: () -> Void = {}

    private enum Step: Equatable {
        case asking
        case checking
        case failed(String)
    }

    @State private var step: Step = .asking
    @State private var server = ""
    @State private var user = ""
    @State private var password = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    ConnectorMark(letters: ConnectorSetupWords.letters(.email), filled: true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Connect \(ConnectorSetupWords.Email.name)").appText(.reading).fontWeight(.semibold)
                        Text(ConnectorSetupWords.sheetSubtitle(.email)).appText(.fine).foregroundStyle(.secondary)
                    }
                }
                Text("Agents will be able to").appText(.fine).fontWeight(.semibold).foregroundStyle(.secondary)
                    .textCase(.uppercase)
                VStack(spacing: 0) {
                    ForEach(Array(ConnectorSetupWords.abilities(.email).enumerated()), id: \.offset) { index, ability in
                        if index > 0 { Divider() }
                        Text(ability).appText(.supporting)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                    }
                }
                .paperRaised(in: RoundedRectangle(cornerRadius: 8))
                fields
                Text(ConnectorSetupWords.sheetChoose(.email)).appText(.fine).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                status
            }
            .padding(20)
            Divider()
            HStack(spacing: 8) {
                Text(ConnectorSetupWords.Email.sheetFoot).appText(.fine).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.paper).keyboardShortcut(.cancelAction)
                Button(ConnectorSetupWords.Email.button) { Task { await connect() } }
                    .buttonStyle(.paperProminent).keyboardShortcut(.defaultAction)
                    .disabled(!isComplete || step == .checking)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .frame(width: 500)
        .paperSheet()
    }

    private var fields: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(ConnectorSetupWords.Email.intro).appText(.fine).fixedSize(horizontal: false, vertical: true)
            LabeledContent(ConnectorSetupWords.Email.serverLabel) {
                TextField(ConnectorSetupWords.Email.serverLabel, text: $server,
                          prompt: Text(ConnectorSetupWords.Email.serverPrompt))
                    .labelsHidden().textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
            }
            LabeledContent(ConnectorSetupWords.Email.userLabel) {
                TextField(ConnectorSetupWords.Email.userLabel, text: $user,
                          prompt: Text(ConnectorSetupWords.Email.userPrompt))
                    .labelsHidden().textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
            }
            LabeledContent(ConnectorSetupWords.Email.passwordLabel) {
                SecureField(ConnectorSetupWords.Email.passwordLabel, text: $password,
                            prompt: Text(ConnectorSetupWords.Email.passwordPrompt))
                    .labelsHidden().textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await connect() } }
            }
        }
        .disabled(step == .checking)
    }

    @ViewBuilder private var status: some View {
        switch step {
        case .asking:
            EmptyView()
        case .checking:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(ConnectorSetupWords.Email.checking).appText(.fine).foregroundStyle(.secondary)
            }
        case .failed(let why):
            Text(why).appText(.fine).tinted(.failure).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func trimmed(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// All three fields have text. The password is sent as typed: spaces can be part of it.
    private var isComplete: Bool {
        !trimmed(server).isEmpty && !trimmed(user).isEmpty && !password.isEmpty
    }

    private func connect() async {
        guard isComplete, step != .checking else { return }
        step = .checking
        switch await model.signInWithEmail(server: trimmed(server), user: trimmed(user), password: password, on: host) {
        case .success:
            password = ""
            onConnected()
            dismiss()
        case .failure(let problem):
            step = .failed(problem.words)
        }
    }
}
