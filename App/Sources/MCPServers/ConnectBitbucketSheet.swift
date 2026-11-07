import AgentsKitCore
import AppKit
import SwiftUI

/// Connect Bitbucket (#3785): the Connect Forgejo sheet's shape for Bitbucket Cloud, which has
/// no device page. An Atlassian API token with its account's email, or an access token with no
/// email, which the host checks with Bitbucket and keeps. The token goes to the host only.
struct ConnectBitbucketSheet: View {
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
    @State private var email = ""
    @State private var token = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    ConnectorMark(letters: ConnectorSetupWords.letters(.bitbucket), filled: true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ConnectorSetupWords.Bitbucket.title).appText(.reading).fontWeight(.semibold)
                        Text(ConnectorSetupWords.sheetSubtitle(.bitbucket)).appText(.fine).foregroundStyle(.secondary)
                    }
                }
                Text("Agents will be able to").appText(.fine).fontWeight(.semibold).foregroundStyle(.secondary)
                    .textCase(.uppercase)
                VStack(spacing: 0) {
                    ForEach(Array(ConnectorSetupWords.abilities(.bitbucket).enumerated()), id: \.offset) { index, ability in
                        if index > 0 { Divider() }
                        Text(ability).appText(.supporting)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                    }
                }
                .paperRaised(in: RoundedRectangle(cornerRadius: 8))
                tokenFields
                Text(ConnectorSetupWords.sheetChoose(.bitbucket)).appText(.fine).foregroundStyle(.secondary)
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
                    Button(ConnectorSetupWords.Bitbucket.tokenButton) { Task { await connect() } }
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
            Text(ConnectorSetupWords.Bitbucket.tokenIntro).appText(.fine).fixedSize(horizontal: false, vertical: true)
            LabeledContent(ConnectorSetupWords.Bitbucket.emailLabel) {
                TextField(ConnectorSetupWords.Bitbucket.emailLabel, text: $email,
                          prompt: Text(ConnectorSetupWords.Bitbucket.emailPrompt))
                    .labelsHidden().textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
            }
            LabeledContent(ConnectorSetupWords.Bitbucket.tokenLabel) {
                SecureField(ConnectorSetupWords.Bitbucket.tokenLabel, text: $token,
                            prompt: Text(ConnectorSetupWords.Bitbucket.tokenPrompt))
                    .labelsHidden().textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await connect() } }
            }
            Button(ConnectorSetupWords.Bitbucket.newTokenButton) { open(ConnectorSetupWords.Bitbucket.newTokenURL) }
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
                Text(ConnectorSetupWords.Bitbucket.checking).appText(.fine).foregroundStyle(.secondary)
            }
        case .failed(let why):
            Text(why).appText(.fine).tinted(.failure).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func connect() async {
        let typed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty, step != .checking else { return }
        step = .checking
        let user = email.trimmingCharacters(in: .whitespacesAndNewlines)
        switch await model.signInWithToken(.bitbucket, url: nil, user: user.isEmpty ? nil : user, token: typed, on: host) {
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
        NSWorkspace.shared.open(url) // store-ok: Atlassian in the browser, not a path
    }
}
