import AgentsKitCore
import AppKit
import SwiftUI

/// The one token sheet (#3802): Connect Forgejo (#3752), Connect Bitbucket (#3785) and Connect
/// Azure DevOps, the Connect GitLab sheet's Access token way alone, for a provider with no
/// device page. Its one field beside the token (Forgejo's address, Bitbucket's Atlassian email,
/// Azure DevOps's organization) and the token, which the host checks with the provider and
/// keeps. The token goes to the host only.
struct ConnectTokenSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var words: ConnectorSetupWords.TokenSheet
    var host: MachineRef
    var onConnected: () -> Void = {}

    /// again is the connection Connect Again\u{2026} is for: the sheet opens with its field.
    init(_ words: ConnectorSetupWords.TokenSheet, host: MachineRef, again: DaemonAPI.Connection? = nil,
         onConnected: @escaping () -> Void = {}) {
        self.words = words
        self.host = host
        self.onConnected = onConnected
        _field = State(initialValue: again.map(words.again) ?? "")
    }

    private enum Step: Equatable {
        case asking
        case checking
        case failed(String)
    }

    @State private var step: Step = .asking
    @State private var field: String
    @State private var token = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    ConnectorMark(letters: ConnectorSetupWords.letters(words.provider), filled: true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(words.title).appText(.reading).fontWeight(.semibold)
                        Text(ConnectorSetupWords.sheetSubtitle(words.provider)).appText(.fine).foregroundStyle(.secondary)
                    }
                }
                Text("Agents will be able to").appText(.fine).fontWeight(.semibold).foregroundStyle(.secondary)
                    .textCase(.uppercase)
                VStack(spacing: 0) {
                    ForEach(Array(ConnectorSetupWords.abilities(words.provider).enumerated()), id: \.offset) { index, ability in
                        if index > 0 { Divider() }
                        Text(ability).appText(.supporting)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                    }
                }
                .paperRaised(in: RoundedRectangle(cornerRadius: 8))
                tokenFields
                Text(ConnectorSetupWords.sheetChoose(words.provider)).appText(.fine).foregroundStyle(.secondary)
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
                    Button(ConnectorSetupWords.continueButton(words.provider)) { Task { await connect() } }
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
            Text(words.intro).appText(.fine).fixedSize(horizontal: false, vertical: true)
            LabeledContent(words.fieldLabel) {
                TextField(words.fieldLabel, text: $field, prompt: Text(words.fieldPrompt))
                    .labelsHidden().textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
            }
            LabeledContent(words.tokenLabel) {
                SecureField(words.tokenLabel, text: $token, prompt: Text(words.tokenPrompt))
                    .labelsHidden().textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await connect() } }
            }
            Button(words.newTokenButton) { open(words.newTokenURL(field)) }
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
                Text(words.checking).appText(.fine).foregroundStyle(.secondary)
            }
        case .failed(let why):
            SheetNote(text: why, reservesSpace: false)
        }
    }

    private func connect() async {
        let typed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty, step != .checking else { return }
        step = .checking
        let given = field.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = given.isEmpty ? nil : given
        switch await model.signInWithToken(words.provider, url: words.field == .url ? value : nil,
                                           user: words.field == .user ? value : nil, token: typed, on: host) {
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
        NSWorkspace.shared.open(url)
    }
}
