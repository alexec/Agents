import AgentsKitCore
import AppKit
import SwiftUI

/// Connect Forgejo (#3752): the Connect GitLab sheet's Access token way, alone, for Codeberg or
/// any Forgejo or Gitea (Forgejo has no device page). Its address (Codeberg when empty) and an
/// access token, which the host checks with that Forgejo and keeps. The token goes to the host
/// only.
struct ConnectForgejoSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var host: MachineRef
    var onConnected: () -> Void = {}

    /// again is the connection Connect Again\u{2026} is for: the sheet opens with its address.
    init(host: MachineRef, again: DaemonAPI.Connection? = nil, onConnected: @escaping () -> Void = {}) {
        self.host = host
        self.onConnected = onConnected
        _address = State(initialValue: again.map(ConnectorSetupWords.Forgejo.again) ?? "")
    }

    private enum Step: Equatable {
        case asking
        case checking
        case failed(String)
    }

    @State private var step: Step = .asking
    @State private var address: String
    @State private var token = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    ConnectorMark(letters: ConnectorSetupWords.letters(.forgejo), filled: true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ConnectorSetupWords.Forgejo.title).appText(.reading).fontWeight(.semibold)
                        Text(ConnectorSetupWords.sheetSubtitle(.forgejo)).appText(.fine).foregroundStyle(.secondary)
                    }
                }
                Text("Agents will be able to").appText(.fine).fontWeight(.semibold).foregroundStyle(.secondary)
                    .textCase(.uppercase)
                VStack(spacing: 0) {
                    ForEach(Array(ConnectorSetupWords.abilities(.forgejo).enumerated()), id: \.offset) { index, ability in
                        if index > 0 { Divider() }
                        Text(ability).appText(.supporting)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                    }
                }
                .paperRaised(in: RoundedRectangle(cornerRadius: 8))
                tokenFields
                Text(ConnectorSetupWords.sheetChoose(.forgejo)).appText(.fine).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                status
            }
            .padding(20)
            Divider()
            HStack(spacing: 8) {
                Text(ConnectorSetupWords.sheetFoot).appText(.fine).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.paper).keyboardShortcut(.cancelAction)
                if step != .checking {
                    Button(ConnectorSetupWords.Forgejo.tokenButton) { Task { await connect() } }
                        .buttonStyle(.paperProminent).keyboardShortcut(.defaultAction)
                        .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .frame(width: 500)
        .paperSheet()
    }

    private var tokenFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(ConnectorSetupWords.Forgejo.tokenIntro).appText(.fine).fixedSize(horizontal: false, vertical: true)
            LabeledContent(ConnectorSetupWords.Forgejo.addressLabel) {
                TextField(ConnectorSetupWords.Forgejo.addressLabel, text: $address,
                          prompt: Text(ConnectorSetupWords.Forgejo.addressPrompt))
                    .labelsHidden().textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
            }
            LabeledContent(ConnectorSetupWords.Forgejo.tokenLabel) {
                SecureField(ConnectorSetupWords.Forgejo.tokenLabel, text: $token,
                            prompt: Text(ConnectorSetupWords.Forgejo.tokenPrompt))
                    .labelsHidden().textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await connect() } }
            }
            Button(ConnectorSetupWords.Forgejo.newTokenButton) { open(ConnectorSetupWords.Forgejo.newTokenURL(address)) }
                .buttonStyle(.link).appText(.fine)
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
                Text(ConnectorSetupWords.Forgejo.checking).appText(.fine).foregroundStyle(.secondary)
            }
        case .failed(let why):
            Text(why).appText(.fine).tinted(.failure).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func connect() async {
        let typed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty, step != .checking else { return }
        step = .checking
        let url = address.trimmingCharacters(in: .whitespacesAndNewlines)
        switch await model.signInWithToken(.forgejo, url: url.isEmpty ? nil : url, token: typed, on: host) {
        case .success:
            token = ""
            onConnected()
            dismiss()
        case .failure(let problem):
            step = .failed(problem.words)
        }
    }

    private func open(_ address: String) {
        guard let url = URL(string: address) else { return }
        NSWorkspace.shared.open(url) // store-ok: a Forgejo in the browser, not a path
    }
}
