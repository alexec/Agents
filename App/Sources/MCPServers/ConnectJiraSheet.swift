import AgentsKitCore
import AppKit
import SwiftUI

/// Connect Jira (#3304): one Atlassian sign-in for Jira and Confluence (#3248), with two ways
/// in, as Connect GitLab has. Atlassian Cloud is Linear's code flow: the host gives the address,
/// an authentication session opens it, and the code that comes back goes to the host, which
/// keeps the app's client secret. API token is for Jira Data Center, or Jira Cloud without the
/// sign-in: the site, the email (Cloud only) and the token, which the host checks with the site.
/// Either way the sheet ends on the one real read that proves it, the site's newest issue, and
/// Done closes it.
struct ConnectJiraSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.webAuthenticationSession) private var session

    var host: MachineRef
    var onConnected: () -> Void = {}

    /// The catalogue's search for the Jira connector, after the sheet.
    static let search = "jira"

    private enum Way: Hashable { case signIn, token }

    private enum Step: Equatable {
        case asking
        case starting
        case waiting(DaemonAPI.ConnectionSignIn)
        case finishing
        case checking
        case connected(DaemonAPI.Connection)
        case failed(String)
    }

    @State private var way: Way = .signIn
    @State private var step: Step = .asking
    @State private var site = ""
    @State private var email = ""
    @State private var token = ""

    private typealias Words = ConnectorSetupWords.Jira

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    ConnectorMark(letters: Words.letters, filled: true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Words.title).appText(.reading).fontWeight(.semibold)
                        Text(Words.subtitle).appText(.fine).foregroundStyle(.secondary)
                    }
                }
                if case .connected(let c) = step {
                    connected(c)
                } else {
                    Picker("Connect with", selection: $way) {
                        Text(Words.signInWay).tag(Way.signIn)
                        Text(Words.tokenWay).tag(Way.token)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                    .disabled(isBusy)
                    Text("Agents will be able to").appText(.fine).fontWeight(.semibold).foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    VStack(spacing: 0) {
                        ForEach(Array(Words.abilities.enumerated()), id: \.offset) { index, ability in
                            if index > 0 { Divider() }
                            Text(ability).appText(.supporting)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12).padding(.vertical, 8)
                        }
                    }
                    .paperRaised(in: RoundedRectangle(cornerRadius: 8))
                    if way == .token { tokenFields }
                    Text(Words.choose).appText(.fine).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    status
                }
            }
            .padding(20)
            Divider()
            HStack(spacing: 8) {
                Text(ConnectorSetupWords.sheetFoot).appText(.fine).foregroundStyle(.secondary)
                Spacer()
                buttons
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .frame(width: 500)
        .paperSheet()
        .onChange(of: way) { if case .failed = step { step = .asking } }
        .onDisappear {
            if case .waiting(let flow) = step { Task { await model.cancelSignIn(flow.flowID, on: host) } }
        }
    }

    private var isBusy: Bool {
        switch step {
        case .starting, .waiting, .finishing, .checking: true
        default: false
        }
    }

    private var tokenFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(Words.tokenIntro).appText(.fine).fixedSize(horizontal: false, vertical: true)
            LabeledContent(Words.siteLabel) {
                TextField(Words.siteLabel, text: $site, prompt: Text(Words.sitePrompt))
                    .labelsHidden().textFieldStyle(.roundedBorder).autocorrectionDisabled()
            }
            LabeledContent(Words.emailLabel) {
                TextField(Words.emailLabel, text: $email, prompt: Text(Words.emailPrompt))
                    .labelsHidden().textFieldStyle(.roundedBorder).autocorrectionDisabled()
            }
            LabeledContent(Words.tokenLabel) {
                SecureField(Words.tokenLabel, text: $token, prompt: Text(Words.tokenPrompt))
                    .labelsHidden().textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await connectWithToken() } }
            }
            Button(Words.newTokenButton) { open(Words.newTokenURL) }
                .buttonStyle(.link).appText(.fine)
        }
        .disabled(isBusy)
    }

    /// The end: where it connected, as whom, and the site's newest issue.
    private func connected(_ c: DaemonAPI.Connection) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Paper.accent)
                Text(Words.connected(c)).appText(.supporting).fontWeight(.semibold)
            }
            Text(Words.proof(c)).appText(.fine).fixedSize(horizontal: false, vertical: true)
            if let address = c.newest?.url {
                Button("Open in Jira") { open(address) }.buttonStyle(.link).appText(.fine)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Paper.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder private var status: some View {
        switch step {
        case .asking, .connected:
            EmptyView()
        case .starting, .finishing, .waiting, .checking:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(statusWords).appText(.fine).fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Paper.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        case .failed(let why):
            Text(why).appText(.fine).tinted(.failure).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var statusWords: String {
        switch step {
        case .waiting(let flow): ConnectorSetupWords.sheetStatus(flow)
        case .finishing: ConnectorSetupWords.Linear.finishing
        case .checking: Words.checking
        default: "Asking the machine for Atlassian's address\u{2026}"
        }
    }

    @ViewBuilder private var buttons: some View {
        switch (way, step) {
        case (_, .connected):
            Button(Words.done) { onConnected(); dismiss() }
                .buttonStyle(.paperProminent).keyboardShortcut(.defaultAction)
        case (.signIn, .asking):
            cancelButton
            Button(Words.continueButton) { Task { await start() } }
                .buttonStyle(.paperProminent).keyboardShortcut(.defaultAction).fixedSize()
        case (.signIn, .failed):
            cancelButton
            Button("Try Again") { Task { await start() } }.buttonStyle(.paperProminent)
        case (.token, .asking), (.token, .failed):
            cancelButton
            Button(Words.tokenButton) { Task { await connectWithToken() } }
                .buttonStyle(.paperProminent).keyboardShortcut(.defaultAction)
                .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || site.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        default:
            cancelButton
        }
    }

    private var cancelButton: some View {
        Button("Cancel") { Task { await cancel() } }.buttonStyle(.paper).keyboardShortcut(.cancelAction)
    }

    private func start() async {
        step = .starting
        let flow: DaemonAPI.ConnectionSignIn
        switch await model.startSignIn(.atlassian, on: host) {
        case .success(let started): flow = started
        case .failure(let problem): step = .failed(problem.words); return
        }
        step = .waiting(flow)
        let outcome: CodeFlowSignIn.Outcome
        if let folder = ControlConfig.walkFolder {
            outcome = await model.handOffSignIn(flow, to: folder, on: host)
        } else {
            outcome = await CodeFlowSignIn.finish(flow, in: session) { request in
                step = .finishing
                return await model.completeSignIn(request, on: host).mapError { CodeFlowSignIn.Problem($0.words) }
            }
        }
        switch outcome {
        case .connected(let ended):
            if let c = ended.connection { step = .connected(c) } else { onConnected(); dismiss() }
        case .cancelled:
            await model.cancelSignIn(flow.flowID, on: host)
            step = .asking
        case .failed(let why):
            step = .failed(why)
        }
    }

    private func connectWithToken() async {
        let typed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty, !isBusy else { return }
        step = .checking
        let user = email.trimmingCharacters(in: .whitespacesAndNewlines)
        switch await model.signInWithToken(.atlassian, url: site.trimmingCharacters(in: .whitespacesAndNewlines),
                                           user: user.isEmpty ? nil : user, token: typed, on: host) {
        case .success(let c):
            token = ""
            step = .connected(c)
        case .failure(let problem):
            step = .failed(problem.words)
        }
    }

    private func cancel() async {
        if case .waiting(let flow) = step {
            step = .asking
            await model.cancelSignIn(flow.flowID, on: host)
        }
        dismiss()
    }

    private func open(_ address: String) {
        guard let url = URL(string: address) else { return }
        NSWorkspace.shared.open(url)
    }
}
