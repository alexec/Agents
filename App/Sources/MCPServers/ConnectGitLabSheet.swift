import AgentsKitCore
import AppKit
import SwiftUI

/// Connect GitLab (#1630): the Connect GitHub sheet with two ways in. gitlab.com is the
/// host's device flow: the sheet shows the code, copies it, opens gitlab.com's device page,
/// waits, and closes by itself. Access token is for a self-managed GitLab (it has no Agents
/// application) or gitlab.com without the sign-in: its address and a personal access token,
/// which the host checks with that GitLab and keeps. The token goes to the host only.
struct ConnectGitLabSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var host: MachineRef
    var onConnected: () -> Void = {}

    /// again is the ended connection Connect Again\u{2026} is for: the sheet opens the way it
    /// was made, with its address (#1865).
    init(host: MachineRef, again: DaemonAPI.Connection? = nil, onConnected: @escaping () -> Void = {}) {
        self.host = host
        self.onConnected = onConnected
        let start = again.map(ConnectorSetupWords.GitLab.again)
        _way = State(initialValue: start?.withToken == true ? .token : .signIn)
        _address = State(initialValue: start?.address ?? "")
    }

    private enum Way: Hashable { case signIn, token }

    private enum Step: Equatable {
        case asking
        case starting
        case waiting(DaemonAPI.ConnectionSignIn)
        case checking
        case failed(String)
    }

    @State private var way: Way
    @State private var step: Step = .asking
    @State private var address: String
    @State private var token = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    ConnectorMark(letters: ConnectorSetupWords.letters(.gitlab), filled: true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Connect GitLab").appText(.reading).fontWeight(.semibold)
                        Text(ConnectorSetupWords.sheetSubtitle(.gitlab)).appText(.fine).foregroundStyle(.secondary)
                    }
                }
                Picker("Connect with", selection: $way) {
                    Text(ConnectorSetupWords.GitLab.signInWay).tag(Way.signIn)
                    Text(ConnectorSetupWords.GitLab.tokenWay).tag(Way.token)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .disabled(isBusy)
                Text("Agents will be able to").appText(.fine).fontWeight(.semibold).foregroundStyle(.secondary)
                    .textCase(.uppercase)
                VStack(spacing: 0) {
                    ForEach(Array(ConnectorSetupWords.abilities(.gitlab).enumerated()), id: \.offset) { index, ability in
                        if index > 0 { Divider() }
                        Text(ability).appText(.supporting)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                    }
                }
                .paperRaised(in: RoundedRectangle(cornerRadius: 8))
                if way == .token { tokenFields }
                Text(ConnectorSetupWords.sheetChoose(.gitlab)).appText(.fine).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
            // Closed while gitlab.com was still out: the host stops polling for it.
            if case .waiting(let flow) = step { Task { await model.cancelSignIn(flow.flowID, on: host) } }
        }
    }

    private var isBusy: Bool {
        switch step {
        case .starting, .waiting, .checking: true
        default: false
        }
    }

    private var tokenFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(ConnectorSetupWords.GitLab.tokenIntro).appText(.fine).fixedSize(horizontal: false, vertical: true)
            LabeledContent(ConnectorSetupWords.GitLab.addressLabel) {
                TextField(ConnectorSetupWords.GitLab.addressLabel, text: $address,
                          prompt: Text(ConnectorSetupWords.GitLab.addressPrompt))
                    .labelsHidden().textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
            }
            LabeledContent(ConnectorSetupWords.GitLab.tokenLabel) {
                SecureField(ConnectorSetupWords.GitLab.tokenLabel, text: $token,
                            prompt: Text(ConnectorSetupWords.GitLab.tokenPrompt))
                    .labelsHidden().textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await connectWithToken() } }
            }
            Button("Make a Token on GitLab") { open(ConnectorSetupWords.GitLab.newTokenURL(address)) }
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
                Text("Asking GitLab for a code\u{2026}").appText(.fine).foregroundStyle(.secondary)
            }
        case .checking:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(ConnectorSetupWords.GitLab.checking).appText(.fine).foregroundStyle(.secondary)
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
                Button("Open gitlab.com Again") { open(flow.verificationURL) }
                    .buttonStyle(.link).appText(.fine)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Paper.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        case .failed(let why):
            Text(why).appText(.fine).tinted(.failure).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var buttons: some View {
        Button("Cancel") { Task { await cancel() } }.buttonStyle(.paper).keyboardShortcut(.cancelAction)
        switch (way, step) {
        case (.signIn, .asking):
            Button(ConnectorSetupWords.continueButton(.gitlab)) { Task { await start() } }
                .buttonStyle(.paperProminent).keyboardShortcut(.defaultAction)
        case (.signIn, .failed):
            Button("Try Again") { Task { await start() } }.buttonStyle(.paperProminent)
        case (.token, .asking), (.token, .failed):
            Button(ConnectorSetupWords.GitLab.tokenButton) { Task { await connectWithToken() } }
                .buttonStyle(.paperProminent).keyboardShortcut(.defaultAction)
                .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        default:
            EmptyView()
        }
    }

    private func start() async {
        step = .starting
        let started: DaemonAPI.ConnectionSignIn
        switch await model.startSignIn(.gitlab, on: host) {
        case .success(let flow): started = flow
        case .failure(let problem): step = .failed(problem.words); return
        }
        step = .waiting(started)
        copy(started.userCode ?? "")
        open(started.verificationURL)
        while case .waiting(let shown) = step, shown.flowID == started.flowID {
            let flow: DaemonAPI.ConnectionSignIn
            switch await model.waitForSignIn(started.flowID, on: host) {
            case .failure(let problem): step = .failed(problem.words); return
            case .success(let now): flow = now
            }
            switch flow.status {
            case .waiting:
                continue
            case .connected:
                onConnected()
                dismiss()
                return
            case .cancelled:
                return
            case .expired, .denied, .failed:
                step = .failed(ConnectorSetupWords.sheetStatus(flow))
            }
        }
    }

    private func connectWithToken() async {
        let typed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty, !isBusy else { return }
        step = .checking
        let url = address.trimmingCharacters(in: .whitespacesAndNewlines)
        switch await model.signInWithToken(.gitlab, url: url.isEmpty ? nil : url, token: typed, on: host) {
        case .success:
            token = ""
            onConnected()
            dismiss()
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

    private func copy(_ code: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
    }

    private func open(_ address: String) {
        guard let url = URL(string: address) else { return }
        NSWorkspace.shared.open(url) // store-ok: gitlab.com in the browser, not a path
    }
}
