import AgentsKitCore
import AppKit
import SwiftUI

/// Connect Azure DevOps (#3802, #3921): the Connect GitLab sheet's two ways in, with the
/// organization for both. Personal access token is the one token sheet's way: the token goes
/// to the host, which checks it with the organization and keeps it. Microsoft Entra is the
/// host's device flow on Entra, for dev.azure.com: the sheet shows the code, copies it, opens
/// Microsoft's device page, waits, and closes by itself. The host renews that sign-in.
struct ConnectAzureDevOpsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var host: MachineRef
    var onConnected: () -> Void = {}

    private typealias Words = ConnectorSetupWords.AzureDevOps

    /// again is the connection Connect Again\u{2026} is for: the sheet opens the way it was
    /// made, with its organization.
    init(host: MachineRef, again: DaemonAPI.Connection? = nil, onConnected: @escaping () -> Void = {}) {
        self.host = host
        self.onConnected = onConnected
        _way = State(initialValue: again.map(Words.againWithEntra) == true ? .signIn : .token)
        _organization = State(initialValue: again.map(Words.again) ?? "")
    }

    private enum Way: Hashable { case token, signIn }

    private enum Step: Equatable {
        case asking
        case starting
        case waiting(DaemonAPI.ConnectionSignIn)
        case checking
        case failed(String)
    }

    @State private var way: Way
    @State private var step: Step = .asking
    @State private var organization: String
    @State private var token = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    ConnectorMark(letters: ConnectorSetupWords.letters(.azuredevops), filled: true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Words.title).appText(.reading).fontWeight(.semibold)
                        Text(ConnectorSetupWords.sheetSubtitle(.azuredevops)).appText(.fine).foregroundStyle(.secondary)
                    }
                }
                Picker("Connect with", selection: $way) {
                    Text(Words.tokenWay).tag(Way.token)
                    Text(Words.signInWay).tag(Way.signIn)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .disabled(isBusy)
                Text("Agent Loops will be able to").appText(.fine).fontWeight(.semibold).foregroundStyle(.secondary)
                    .textCase(.uppercase)
                VStack(spacing: 0) {
                    ForEach(Array(ConnectorSetupWords.abilities(.azuredevops).enumerated()), id: \.offset) { index, ability in
                        if index > 0 { Divider() }
                        Text(ability).appText(.supporting)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                    }
                }
                .paperRaised(in: RoundedRectangle(cornerRadius: 8))
                fields
                Text(way == .token ? ConnectorSetupWords.sheetChoose(.azuredevops) : Words.signInChoose)
                    .appText(.fine).foregroundStyle(.secondary)
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
            // Closed while Microsoft's page was still out: the host stops polling for it.
            if case .waiting(let flow) = step { Task { await model.cancelSignIn(flow.flowID, on: host) } }
        }
    }

    private var isBusy: Bool {
        switch step {
        case .starting, .waiting, .checking: true
        default: false
        }
    }

    private var given: String { organization.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var fields: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(way == .token ? Words.tokenIntro : Words.signInIntro).appText(.fine)
                .fixedSize(horizontal: false, vertical: true)
            LabeledContent(Words.addressLabel) {
                TextField(Words.addressLabel, text: $organization, prompt: Text(Words.addressPrompt))
                    .labelsHidden().textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .onSubmit { if way == .signIn { Task { await start() } } }
            }
            if way == .token {
                LabeledContent(Words.tokenLabel) {
                    SecureField(Words.tokenLabel, text: $token, prompt: Text(Words.tokenPrompt))
                        .labelsHidden().textFieldStyle(.roundedBorder)
                        .onSubmit { Task { await connectWithToken() } }
                }
                Button(Words.newTokenButton) { open(Words.newTokenURL(organization)) }
                    .buttonStyle(.link).appText(.fine)
            }
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
                Text(Words.starting).appText(.fine).foregroundStyle(.secondary)
            }
        case .checking:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(Words.checking).appText(.fine).foregroundStyle(.secondary)
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
                Button(Words.openAgain) { open(flow.verificationURL) }
                    .buttonStyle(.link).appText(.fine)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Paper.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        case .failed(let why):
            SheetNote(text: why, reservesSpace: false)
        }
    }

    @ViewBuilder private var buttons: some View {
        Button("Cancel") { Task { await cancel() } }.buttonStyle(.paper).keyboardShortcut(.cancelAction)
        switch (way, step) {
        case (.signIn, .asking), (.signIn, .failed):
            Button(Words.signInButton) { Task { await start() } }
                .buttonStyle(.paperProminent).keyboardShortcut(.defaultAction)
                .disabled(given.isEmpty)
        case (.token, .asking), (.token, .failed):
            Button(Words.tokenButton) { Task { await connectWithToken() } }
                .buttonStyle(.paperProminent).keyboardShortcut(.defaultAction)
                .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        default:
            EmptyView()
        }
    }

    private func start() async {
        guard !given.isEmpty, !isBusy else { return }
        step = .starting
        let started: DaemonAPI.ConnectionSignIn
        switch await model.startSignIn(.azuredevops, url: given, on: host) {
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
        switch await model.signInWithToken(.azuredevops, url: given.isEmpty ? nil : given, token: typed, on: host) {
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
        NSWorkspace.shared.open(url)
    }
}
