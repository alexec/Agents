import AgentsKitCore
import AppKit
import SwiftUI

/// Connect GitHub (#1336, frame B): the one sheet. It says what Agents will be able to do,
/// then Continue on github.com starts the host's device flow (#1335): the sheet shows the
/// code, copies it, opens github.com/login/device, waits, and closes by itself once GitHub
/// says yes. When the Agents app is not installed on the folder's repository, it stays
/// open for one more step: the install link. Personal access token (#3945) is the second way
/// in, as GitLab's sheet has, for an organisation that does not let the App in: the host
/// checks the token with github.com and keeps it. The token goes to the host only.
struct ConnectGitHubSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var host: MachineRef
    /// The folder whose page opened it, for the install step; nil from Connectors.
    var folder: FolderKey?
    var onConnected: () -> Void = {}

    /// again is the ended connection Connect Again\u{2026} is for: the sheet opens the way it
    /// was made.
    init(host: MachineRef, folder: FolderKey? = nil, again: DaemonAPI.Connection? = nil,
         onConnected: @escaping () -> Void = {}) {
        self.host = host
        self.folder = folder
        self.onConnected = onConnected
        _way = State(initialValue: again?.byToken == true ? .token : .signIn)
    }

    private enum Way: Hashable { case signIn, token }

    private enum Step: Equatable {
        case asking
        case starting
        case waiting(DaemonAPI.ConnectionSignIn)
        case checking
        case install(login: String, repository: String)
        case failed(String)
    }

    @State private var way: Way
    @State private var step: Step = .asking
    @State private var token = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    ConnectorMark(letters: "GH", filled: true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Connect GitHub").appText(.reading).fontWeight(.semibold)
                        Text(ConnectorSetupWords.sheetSubtitle).appText(.fine).foregroundStyle(.secondary)
                    }
                }
                Picker("Connect with", selection: $way) {
                    Text(Tokens.signInWay).tag(Way.signIn)
                    Text(Tokens.tokenWay).tag(Way.token)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .disabled(isBusy)
                Text("Agent Loops will be able to").appText(.fine).fontWeight(.semibold).foregroundStyle(.secondary)
                    .textCase(.uppercase)
                VStack(spacing: 0) {
                    ForEach(Array(ConnectorSetupWords.abilities.enumerated()), id: \.offset) { index, ability in
                        if index > 0 { Divider() }
                        Text(ability).appText(.supporting)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                    }
                }
                .paperRaised(in: RoundedRectangle(cornerRadius: 8))
                // The repositories are chosen on github.com for the App only, not for a token.
                if way == .token {
                    tokenFields
                } else {
                    Text(ConnectorSetupWords.sheetChoose).appText(.fine).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                status
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
            // Closed while GitHub was still out: the host stops polling for it.
            if case .waiting(let flow) = step { Task { await model.cancelSignIn(flow.flowID, on: host) } }
        }
    }

    private typealias Tokens = ConnectorSetupWords.GitHubTokens

    private var isBusy: Bool {
        switch step {
        case .starting, .waiting, .checking: true
        default: false
        }
    }

    private var tokenFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(Tokens.tokenIntro).appText(.fine).fixedSize(horizontal: false, vertical: true)
            FieldNote(tone: .neutral, text: Tokens.tokenCost)
            LabeledContent(Tokens.tokenLabel) {
                SecureField(Tokens.tokenLabel, text: $token, prompt: Text(Tokens.tokenPrompt))
                    .labelsHidden().textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await connectWithToken() } }
            }
            Button(Tokens.newTokenButton) { open(Tokens.newTokenURL) }
                .buttonStyle(.link).appText(.fine)
        }
        .disabled(isBusy)
    }

    @ViewBuilder private var status: some View {
        switch step {
        case .asking:
            EmptyView()
        case .starting:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Asking GitHub for a code\u{2026}").appText(.fine).foregroundStyle(.secondary)
            }
        case .checking:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(Tokens.checking).appText(.fine).foregroundStyle(.secondary)
            }
        case .waiting(let flow):
            VStack(alignment: .leading, spacing: 8) {
                // No label of its own on the code: a label over a selectable Text sends
                // AppKit's accessibility into endless recursion (see FileLineRow, #71).
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("Your code").appText(.fine).foregroundStyle(.secondary)
                    Text(flow.userCode ?? "").appText(.title).monospaced().textSelection(.enabled)
                    Button("Copy") { copy(flow.userCode ?? "") }.buttonStyle(.paper).appText(.fine)
                }
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(ConnectorSetupWords.sheetStatus(flow)).appText(.fine)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button("Open github.com Again") { open(flow.verificationURL) }
                    .buttonStyle(.link).appText(.fine)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Paper.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        case .install(let login, let repository):
            VStack(alignment: .leading, spacing: 6) {
                Text("Connected as \(login).").appText(.supporting).fontWeight(.semibold)
                Text(ConnectorSetupWords.notInstalled(repository) + " Install it there, then come back.")
                    .appText(.fine).fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Paper.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        case .failed(let why):
            SheetNote(text: why, reservesSpace: false)
        }
    }

    @ViewBuilder private var buttons: some View {
        switch step {
        case .install:
            Button("Done") { dismiss() }.buttonStyle(.paper).keyboardShortcut(.cancelAction)
            Button("Install on github.com") {
                open(ConnectorSetupWords.installURL)
                dismiss()
            }
            .buttonStyle(.paperProminent).keyboardShortcut(.defaultAction)
        default:
            Button("Cancel") { Task { await cancel() } }.buttonStyle(.paper).keyboardShortcut(.cancelAction)
            switch (way, step) {
            case (.signIn, .asking):
                Button(ConnectorSetupWords.continueButton) { Task { await start() } }
                    .buttonStyle(.paperProminent).keyboardShortcut(.defaultAction)
            case (.signIn, .failed):
                Button("Try Again") { Task { await start() } }.buttonStyle(.paperProminent)
            case (.token, .asking), (.token, .failed):
                Button(Tokens.tokenButton) { Task { await connectWithToken() } }
                    .buttonStyle(.paperProminent).keyboardShortcut(.defaultAction)
                    .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            default:
                EmptyView()
            }
        }
    }

    private func start() async {
        step = .starting
        let started: DaemonAPI.ConnectionSignIn
        switch await model.startSignIn(.github, on: host) {
        case .success(let flow): started = flow
        case .failure(let problem): step = .failed(problem.words); return
        }
        step = .waiting(started)
        copy(started.userCode ?? "")
        open(started.verificationURL)
        var flow = started
        while case .waiting(let shown) = step, shown.flowID == started.flowID {
            switch await model.waitForSignIn(started.flowID, on: host) {
            case .failure(let problem):
                step = .failed(problem.words)
                return
            case .success(let now):
                flow = now
            }
            switch flow.status {
            case .waiting:
                continue
            case .connected:
                step = .starting
                onConnected()
                await afterConnecting(flow.connection)
                return
            case .cancelled:
                return
            case .expired, .denied, .failed:
                step = .failed(ConnectorSetupWords.sheetStatus(flow))
            }
        }
    }

    /// A personal access token needs no App on the repository, so the sheet closes at once.
    private func connectWithToken() async {
        let typed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty, !isBusy else { return }
        step = .checking
        switch await model.signInWithToken(.github, url: nil, token: typed, on: host) {
        case .success:
            token = ""
            onConnected()
            dismiss()
        case .failure(let problem):
            step = .failed(problem.words)
        }
    }

    /// Closes, unless the App is not installed on the folder's repository.
    private func afterConnecting(_ connection: DaemonAPI.Connection?) async {
        if let folder, case .success(let setup) = await model.connectorSetup(folder, reading: .fresh),
           setup.installed == false, let repository = setup.repository {
            step = .install(login: connection?.login ?? "you", repository: repository)
            onConnected()
            return
        }
        dismiss()
    }

    private func cancel() async {
        if case .waiting(let flow) = step {
            step = .asking
            await model.cancelSignIn(flow.flowID, on: host)
        }
        dismiss()
    }

    private func copy(_ code: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
    }

    private func open(_ address: String) {
        guard let url = URL(string: address) else { return }
        NSWorkspace.shared.open(url)
    }
}

/// A connector's round mark: its letters on a dark disc, or on a soft one.
struct ConnectorMark: View {
    var letters: String
    var filled = false

    var body: some View {
        Text(letters)
            // Decorative: two letters in a fixed disc, like an avatar, not text to read.
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(filled ? Color.white : Paper.accent)
            .frame(width: 34, height: 34)
            .background(filled ? AnyShapeStyle(Paper.forgeMark) : AnyShapeStyle(Paper.accent.opacity(0.15)), in: Circle())
            .accessibilityHidden(true)
    }
}
