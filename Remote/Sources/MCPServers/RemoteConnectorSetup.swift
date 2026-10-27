import AgentsKitCore
import AuthenticationServices
import SwiftUI

/// A folder's Connectors set-up on the iPhone and iPad (#1336, frame F): the same page as
/// the window's, in the same order, with the slots as a list. Each slot opens its own screen
/// with its proof and its choices. The state is the host's, so all three clients show the
/// same ticks. Where agents run has Add a Machine… and Add Provider… (#2131).
/// The page that shows it reads it (MCPServersListView): at first, when the app comes back
/// to the front, and on a pull (#1684).
struct RemoteConnectorSetup: View {
    let folder: FolderKey
    let folderName: String
    @Binding var setup: DaemonAPI.ConnectorSetup?
    let problem: String?
    let reload: (DaemonAPI.ConnectorSetupReading) async -> Void

    @State private var connecting = false

    var body: some View {
        Section {
            if let problem {
                Text(problem).foregroundStyle(StateTint.failure.style(or: .secondary))
            }
            if let setup {
                connection(setup).paperListRow()
            } else if problem == nil {
                ProgressView().paperListRow()
            }
        } footer: {
            Text(ConnectorSetupWords.intro(folder: folderName, repository: setup?.repository,
                                           site: setup?.siteOrGitHub ?? "github.com"))
        }
        .sheet(isPresented: $connecting) {
            RemoteConnectSheet(provider: setup?.forgeOrGitHub ?? .github, host: folder.host, folder: folder,
                               onConnected: { Task { await reload(.fresh) } })
        }
        if let setup {
            Section(ConnectorSetupWords.setUpHeading(setup)) {
                ForEach(setup.slots) { slot in
                    NavigationLink {
                        RemoteSlotView(folder: folder, folderName: folderName, kind: slot.slot, setup: $setup)
                    } label: {
                        RemoteSlotRow(folder: folder, slot: slot, setup: setup, folderName: folderName)
                    }
                    .paperListRow()
                }
            }
            if setup.connection != nil || setup.events.state != .off {
                Section("Events") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(ConnectorSetupWords.eventsLead(setup.events, forge: setup.forgeOrGitHub))
                        if setup.events.state == .on {
                            Text(ConnectorSetupWords.eventNouns(setup.events.names).joined(separator: " "))
                                .appText(.code).foregroundStyle(Paper.accent)
                            Text(ConnectorSetupWords.workflowsLead(setup.events)
                                 + (setup.events.workflows.isEmpty ? ""
                                    : " " + setup.events.workflows.map(\.name).joined(separator: ", ") + "."))
                                .appText(.fine).foregroundStyle(.secondary)
                        }
                    }
                    .paperListRow()
                }
            }
        }
    }

    @ViewBuilder private func connection(_ setup: DaemonAPI.ConnectorSetup) -> some View {
        if let c = setup.connection, c.state == .connected {
            VStack(alignment: .leading, spacing: 4) {
                Text(ConnectorSetupWords.connected(c)).fontWeight(.semibold)
                Text(ConnectorSetupWords.connectedNote(setup)).appText(.fine).foregroundStyle(.secondary)
                if setup.installed == false, let repository = setup.repository {
                    Text(ConnectorSetupWords.notInstalled(repository)).appText(.fine).tinted(.attention)
                    Link("Install on github.com", destination: URL(string: setup.installURL ?? ConnectorSetupWords.installURL)!)
                        .appText(.fine)
                }
            }
        } else {
            HStack(spacing: 12) {
                Text(setup.connection?.state == .signInAgain ? ConnectorSetupWords.connectAgain(setup.forgeOrGitHub)
                     : ConnectorSetupWords.connectTitle(setup.forgeOrGitHub))
                    .appText(.supporting).fontWeight(.semibold)
                Spacer(minLength: 8)
                Button(ConnectorSetupWords.connectButton(setup.forgeOrGitHub)) { connecting = true }
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}

/// One slot in the list: its mark, "Tasks · GitHub Issues", and one grey line.
private struct RemoteSlotRow: View {
    @Environment(RemoteModel.self) private var model
    let folder: FolderKey
    let slot: DaemonAPI.ConnectorSlot
    let setup: DaemonAPI.ConnectorSetup
    let folderName: String

    private var title: String {
        slot.slot == .workspace ? model.whereAgentsRun(folder.host).title : ConnectorSetupWords.title(slot)
    }

    var body: some View {
        HStack(spacing: 12) {
            RemoteSlotMark(state: slot.state)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(ConnectorSetupWords.heading(slot.slot)) \u{00B7} \(title)")
                Text(subtitle).appText(.fine).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String {
        if let proof = ConnectorSetupWords.proof(slot) { return proof }
        if slot.state == .notConnected, slot.slot != .workspace { return "Comes with \(ConnectorSetupWords.name(setup.forgeOrGitHub))" }
        if slot.slot == .workspace { return model.whereAgentsRun(folder.host).line }
        return ConnectorSetupWords.line(slot, folder: folderName, repository: setup.repository, forge: setup.forgeOrGitHub)
    }
}

private struct RemoteSlotMark: View {
    let state: DaemonAPI.ConnectorSlotState

    var body: some View {
        Group {
            switch state {
            case .read: Image(systemName: "checkmark.circle.fill").foregroundStyle(Paper.accent)
            case .failed, .refused: Image(systemName: "exclamationmark.circle").tinted(.attention)
            case .skipped:
                Circle().strokeBorder(style: StrokeStyle(lineWidth: 1.4, dash: [3, 2.5])).foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
            case .notConnected, .noRemote, .notRead: Image(systemName: "circle").foregroundStyle(.secondary)
            }
        }
        .frame(width: 22)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(state.isDone ? (state == .read ? "Read" : "Skipped") : "Not done")
    }
}

/// A slot's own screen: what it read, and its choices (frames D and G).
private struct RemoteSlotView: View {
    @Environment(RemoteModel.self) private var model
    @Environment(\.openURL) private var openURL
    let folder: FolderKey
    let folderName: String
    let kind: DaemonAPI.ConnectorSlotKind
    @Binding var setup: DaemonAPI.ConnectorSetup?
    @State private var problem: String?
    /// Tasks only (#1682): whether the person's Linear connection is there, nil until read.
    @State private var linearConnected: Bool?
    @State private var connectingLinear = false
    @State private var addingMachine = false
    @State private var addingProvider = false
    /// The providers before Add Provider…: the new one goes on to its New Machine.
    @State private var before: Set<ProviderID> = []
    @State private var making: DaemonAPI.ProviderSummary?

    private var slot: DaemonAPI.ConnectorSlot? { setup?.slot(kind) }

    var body: some View {
        List {
            if let slot, let setup {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            RemoteSlotMark(state: slot.state)
                            Text(kind == .workspace ? model.whereAgentsRun(folder.host).title : ConnectorSetupWords.title(slot))
                                .appText(.reading).fontWeight(.semibold)
                        }
                        if let proof = slot.proof {
                            HStack(alignment: .firstTextBaseline, spacing: 4) {
                                Text(ConnectorSetupWords.proofLead(slot.slot) + ":").foregroundStyle(.secondary)
                                if let number = proof.number {
                                    if let url = proof.url.flatMap(URL.init(string:)) {
                                        Link("#\(number)", destination: url)
                                    } else {
                                        Text("#\(number)")
                                    }
                                }
                                Text(ConnectorSetupWords.proofText(proof)).foregroundStyle(.secondary)
                            }
                            .appText(.supporting)
                        } else {
                            Text(slot.slot == .workspace ? model.whereAgentsRun(folder.host).line
                                 : ConnectorSetupWords.line(slot, folder: folderName, repository: setup.repository,
                                                            forge: setup.forgeOrGitHub))
                                .appText(.supporting)
                                .tinted([.failed, .refused, .noRemote].contains(slot.state) ? .attention : .none)
                                .foregroundStyle(.secondary)
                        }
                        if let problem { Text(problem).appText(.fine).tinted(.failure) }
                    }
                    .paperListRow()
                }
                Section {
                    if slot.state == .failed || slot.state == .refused {
                        if slot.state == .refused {
                            Button(ConnectorSetupWords.grantButton(setup)) {
                                if let url = URL(string: ConnectorSetupWords.grantURL(setup)) { openURL(url) }
                            }
                        }
                        Button("Try Again") { Task { await reload() } }
                    }
                    if kind != .workspace {
                        if slot.state == .skipped {
                            Button("Set Up") { Task { await skip(false) } }
                        } else {
                            Button("Skip") { Task { await skip(true) } }
                        }
                        if kind == .tasks {
                            if linearConnected == false {
                                Button(ConnectorSetupWords.connectLinear) { connectingLinear = true }
                            }
                            Text(ConnectorSetupWords.otherTrackers(linearConnected: linearConnected != false))
                                .appText(.fine).foregroundStyle(.secondary)
                        }
                    } else {
                        // Add a Machine… and Add Provider… in place (#2131).
                        Button(AddMachine.Words.menuItem) { addingMachine = true }
                        if model.isAdmin {
                            Button(AddMachine.Words.addProvider) { addingProvider = true }
                        }
                        if setup.forgeOrGitHub == .github, setup.repository != nil, setup.connection?.state == .connected {
                            Text("GitHub Codespaces: Set up on the Mac.").appText(.fine).foregroundStyle(.secondary)
                        }
                        Text(WhereAgentsRun.addProviderNote).appText(.fine).foregroundStyle(.secondary)
                    }
                }
                .paperListRow()
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Paper.ground)
        .navigationTitle(ConnectorSetupWords.heading(kind))
        .task {
            if kind == .tasks { await readLinear() }
            if kind == .workspace { await model.loadMachineProviders() }
        }
        .sheet(isPresented: $addingMachine) { AddMachineSheet() }
        .sheet(isPresented: $addingProvider, onDismiss: {
            Task {
                await model.loadMachineProviders()
                making = model.machineProviders?.first { !before.contains($0.id) }
            }
        }) {
            AddMachineProviderSheet(editing: nil)
                .onAppear { before = Set((model.machineProviders ?? []).map(\.id)) }
        }
        .sheet(item: $making) { provider in
            NavigationStack { NewMachinePage(picked: provider.id, close: { making = nil }) }
        }
        .sheet(isPresented: $connectingLinear) {
            RemoteConnectSheet(provider: .linear, host: folder.host, onConnected: { Task { await readLinear() } })
        }
    }

    private func readLinear() async {
        guard case .success(let list) = await model.connections(on: folder.host) else { return }
        linearConnected = list.contains { $0.provider == .linear && $0.state == .connected }
    }

    private func skip(_ skipped: Bool) async {
        switch await model.skipConnectorSlot(folder, kind, skipped: skipped) {
        case .success(let fresh): setup = fresh; problem = nil
        case .failure(let failure): problem = failure.words
        }
    }

    private func reload() async {
        switch await model.connectorSetup(folder, reading: .fresh) {
        case .success(let fresh): setup = fresh; problem = nil
        case .failure(let failure): problem = failure.words
        }
    }
}

/// Connect GitHub, Linear or GitLab on the iPhone and iPad (frames B and H). GitHub is the
/// host's device flow: the sheet shows the code, copies it, opens github.com/login/device in
/// Safari, waits, and closes by itself. Linear is the code flow: the sheet opens linear.app in
/// an authentication session and gives the host what came back (CodeFlowSignIn). GitLab
/// (#1630) is the device flow on gitlab.com, or an access token on any GitLab.
struct RemoteConnectSheet: View {
    @Environment(RemoteModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    var provider: DaemonAPI.ConnectionProvider = .github
    let host: MachineRef
    var folder: FolderKey?
    var onConnected: () -> Void = {}

    /// again is the ended GitLab connection Connect Again\u{2026} is for: the sheet opens the way
    /// it was made, with its address (#1865).
    init(provider: DaemonAPI.ConnectionProvider = .github, host: MachineRef, folder: FolderKey? = nil,
         again: DaemonAPI.Connection? = nil, onConnected: @escaping () -> Void = {}) {
        self.provider = provider
        self.host = host
        self.folder = folder
        self.onConnected = onConnected
        let start = provider == .gitlab ? again.map(ConnectorSetupWords.GitLab.again) : nil
        _withToken = State(initialValue: start?.withToken ?? false)
        _address = State(initialValue: start?.address ?? "")
    }

    private enum Step: Equatable {
        case asking, starting
        case waiting(DaemonAPI.ConnectionSignIn)
        case install(login: String, repository: String)
        /// Linear only: the host takes the code that came back.
        case finishing
        /// Linear only: the person closed linear.app's page.
        case cancelled
        /// GitLab's access token: the host checks it.
        case checking
        case failed(String)
    }

    @State private var step: Step = .asking
    /// GitLab only: an access token instead of the sign-in.
    @State private var withToken: Bool
    @State private var address: String
    @State private var token = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(ConnectorSetupWords.sheetSubtitle(provider)).foregroundStyle(.secondary)
                }
                .paperListRow()
                if provider == .gitlab {
                    Section {
                        Picker("Connect with", selection: $withToken) {
                            Text(ConnectorSetupWords.GitLab.signInWay).tag(false)
                            Text(ConnectorSetupWords.GitLab.tokenWay).tag(true)
                        }
                        .pickerStyle(.segmented)
                        .disabled(isBusy)
                    }
                    .paperListRow()
                }
                Section("Agents will be able to") {
                    ForEach(ConnectorSetupWords.abilities(provider), id: \.self) { Text($0) }
                }
                .paperListRow()
                if withToken {
                    Section {
                        TextField(ConnectorSetupWords.GitLab.addressLabel, text: $address,
                                  prompt: Text(ConnectorSetupWords.GitLab.addressPrompt))
                            .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                            .captioned(ConnectorSetupWords.GitLab.addressLabel)
                        SecureField(ConnectorSetupWords.GitLab.tokenLabel, text: $token,
                                    prompt: Text(ConnectorSetupWords.GitLab.tokenPrompt))
                            .onSubmit { Task { await connectWithToken() } }
                            .captioned(ConnectorSetupWords.GitLab.tokenLabel)
                        Button("Make a Token on GitLab") { open(ConnectorSetupWords.GitLab.newTokenURL(address)) }
                    } footer: {
                        Text(ConnectorSetupWords.GitLab.tokenIntro)
                    }
                    .disabled(isBusy)
                    .paperListRow()
                }
                Section {
                    switch step {
                    case .asking:
                        continueButton
                    case .starting:
                        ProgressView()
                    case .waiting(let flow):
                        if let code = flow.userCode {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Your code").appText(.fine).foregroundStyle(.secondary)
                                Text(code).appText(.title).monospaced().fontWeight(.semibold).textSelection(.enabled)
                                Text(ConnectorSetupWords.sheetStatus(flow)).appText(.fine)
                            }
                            Button("Copy Code") { UIPasteboard.general.string = code }
                            Button("Open \(ConnectorSetupWords.site(provider)) Again") { open(flow.verificationURL) }
                        } else {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text(ConnectorSetupWords.sheetStatus(flow)).appText(.fine)
                            }
                        }
                    case .finishing:
                        HStack(spacing: 8) {
                            ProgressView()
                            Text(ConnectorSetupWords.Linear.finishing).appText(.fine)
                        }
                    case .checking:
                        HStack(spacing: 8) {
                            ProgressView()
                            Text(ConnectorSetupWords.GitLab.checking).appText(.fine)
                        }
                    case .install(let login, let repository):
                        Text("Connected as \(login).").fontWeight(.semibold)
                        Text(ConnectorSetupWords.notInstalled(repository)).appText(.fine)
                        Button("Install on github.com") { open(ConnectorSetupWords.installURL); dismiss() }
                    case .cancelled:
                        Text("Cancelled.").foregroundStyle(.secondary)
                        continueButton
                    case .failed(let why):
                        Text(why).tinted(.failure)
                        if withToken { continueButton } else { Button("Try Again") { Task { await start() } } }
                    }
                } footer: {
                    Text(ConnectorSetupWords.sheetChoose(provider) + " " + ConnectorSetupWords.sheetFoot)
                }
                .paperListRow()
            }
            .scrollContentBackground(.hidden)
            .background(Paper.ground)
            .navigationTitle("Connect \(ConnectorSetupWords.name(provider))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(isInstall ? "Done" : "Cancel") { Task { await cancel() } }
                }
            }
        }
        .onChange(of: withToken) { if case .failed = step { step = .asking } }
        .onDisappear {
            if case .waiting(let flow) = step { Task { await model.cancelSignIn(flow.flowID, on: host) } }
        }
    }

    @ViewBuilder private var continueButton: some View {
        if withToken {
            Button(ConnectorSetupWords.GitLab.tokenButton) { Task { await connectWithToken() } }.fontWeight(.semibold)
                .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } else {
            Button(ConnectorSetupWords.continueButton(provider)) { Task { await start() } }.fontWeight(.semibold)
        }
    }

    private var isBusy: Bool {
        switch step {
        case .starting, .waiting, .finishing, .checking: true
        default: false
        }
    }

    private func connectWithToken() async {
        let typed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty, !isBusy else { return }
        step = .checking
        let url = address.trimmingCharacters(in: .whitespacesAndNewlines)
        switch await model.signInWithToken(provider, url: url.isEmpty ? nil : url, token: typed, on: host) {
        case .success:
            token = ""
            onConnected()
            dismiss()
        case .failure(let problem):
            step = .failed(problem.words)
        }
    }

    private var isInstall: Bool { if case .install = step { true } else { false } }

    private func start() async {
        step = .starting
        let started: DaemonAPI.ConnectionSignIn
        switch await model.startSignIn(provider, on: host) {
        case .success(let flow): started = flow
        case .failure(let problem): step = .failed(problem.words); return
        }
        step = .waiting(started)
        if started.grant == .authorizationCode {
            await finishCodeFlow(started)
            return
        }
        // The device flow (GitHub, GitLab): it always has a code.
        UIPasteboard.general.string = started.userCode
        open(started.verificationURL)
        while case .waiting(let shown) = step, shown.flowID == started.flowID {
            let flow: DaemonAPI.ConnectionSignIn
            switch await model.waitForSignIn(started.flowID, on: host) {
            case .success(let now): flow = now
            case .failure(let problem):
                // The link drops while the person is in Safari (#1683): the host may have the token.
                let after = await afterFailedWait(started)
                guard case .waiting(let still) = step, still.flowID == started.flowID else { return }
                guard let after else { step = .failed(problem.words); return }
                flow = after
            }
            switch flow.status {
            case .waiting: continue
            case .connected:
                step = .starting
                onConnected()
                if let folder, case .success(let setup) = await model.connectorSetup(folder, reading: .fresh),
                   setup.installed == false, let repository = setup.repository {
                    step = .install(login: flow.connection?.login ?? "you", repository: repository)
                    return
                }
                dismiss()
                return
            case .cancelled: return
            case .expired, .denied, .failed: step = .failed(ConnectorSetupWords.sheetStatus(flow))
            }
        }
    }

    /// A wait that failed, most often because the link dropped while the person was in Safari
    /// (#1683). When the link is back, the host's connections say whether it has the token.
    /// If not, the wait goes on once more. Nil: it failed.
    private func afterFailedWait(_ started: DaemonAPI.ConnectionSignIn) async -> DaemonAPI.ConnectionSignIn? {
        for _ in 0..<40 where !model.isConnected { try? await Task.sleep(for: .milliseconds(500)) }
        if case .success(let list) = await model.connections(on: host),
           let connection = list.first(where: { $0.provider == started.provider && $0.state == .connected }) {
            var connected = started
            connected.status = .connected
            connected.connection = connection
            return connected
        }
        if case .success(let now) = await model.waitForSignIn(started.flowID, on: host) { return now }
        return nil
    }

    /// The code flow (Linear): the authentication session, then the host finishes it. The
    /// sheet closes by itself once the host says connected, as the Mac's does.
    private func finishCodeFlow(_ started: DaemonAPI.ConnectionSignIn) async {
        let outcome = await CodeFlowSignIn.finish(started, in: webAuthenticationSession) { request in
            step = .finishing
            return await model.completeSignIn(request, on: host).mapError { CodeFlowSignIn.Problem($0.words) }
        }
        switch outcome {
        case .connected:
            onConnected()
            dismiss()
        case .cancelled:
            step = .cancelled
            await model.cancelSignIn(started.flowID, on: host)
        case .failed(let why):
            step = .failed(why)
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
        if let url = URL(string: address) { openURL(url) }
    }
}

/// Connect Email on the iPhone and iPad (#1780): the IMAP server, the user and an app
/// password, which the host checks with one sign-in and keeps. No device page. The password
/// stays in this sheet's state only, and is cleared once it is sent.
struct RemoteConnectEmailSheet: View {
    @Environment(RemoteModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let host: MachineRef
    var onConnected: () -> Void = {}

    private enum Step: Equatable {
        case asking, checking
        case failed(String)
    }

    @State private var step: Step = .asking
    @State private var server = ""
    @State private var user = ""
    @State private var password = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(ConnectorSetupWords.sheetSubtitle(.email)).foregroundStyle(.secondary)
                }
                .paperListRow()
                Section("Agents will be able to") {
                    ForEach(ConnectorSetupWords.abilities(.email), id: \.self) { Text($0) }
                }
                .paperListRow()
                Section {
                    TextField(ConnectorSetupWords.Email.serverLabel, text: $server,
                              prompt: Text(ConnectorSetupWords.Email.serverPrompt))
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .captioned(ConnectorSetupWords.Email.serverLabel)
                    TextField(ConnectorSetupWords.Email.userLabel, text: $user,
                              prompt: Text(ConnectorSetupWords.Email.userPrompt))
                        .keyboardType(.emailAddress).textContentType(.username)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .captioned(ConnectorSetupWords.Email.userLabel)
                    SecureField(ConnectorSetupWords.Email.passwordLabel, text: $password,
                                prompt: Text(ConnectorSetupWords.Email.passwordPrompt))
                        .textContentType(.password)
                        .onSubmit { Task { await connect() } }
                        .captioned(ConnectorSetupWords.Email.passwordLabel)
                } footer: {
                    Text(ConnectorSetupWords.Email.intro)
                }
                .disabled(step == .checking)
                .paperListRow()
                Section {
                    switch step {
                    case .asking:
                        connectButton
                    case .checking:
                        HStack(spacing: 8) {
                            ProgressView()
                            Text(ConnectorSetupWords.Email.checking).appText(.fine)
                        }
                    case .failed(let why):
                        Text(why).tinted(.failure)
                        connectButton
                    }
                } footer: {
                    Text(ConnectorSetupWords.sheetChoose(.email) + " " + ConnectorSetupWords.Email.sheetFoot)
                }
                .paperListRow()
            }
            .scrollContentBackground(.hidden)
            .background(Paper.ground)
            .navigationTitle("Connect \(ConnectorSetupWords.Email.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private var connectButton: some View {
        Button(ConnectorSetupWords.Email.button) { Task { await connect() } }.fontWeight(.semibold)
            .disabled(!isComplete)
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

/// Connectors ▸ Connections on the iPhone and iPad (frame E). The page that shows them
/// reads them, as a folder's set-up (#1684).
struct RemoteConnections: View {
    @Environment(RemoteModel.self) private var model
    let connections: [DaemonAPI.Connection]?
    @Binding var problem: String?
    let reload: () async -> Void
    @State private var connecting: DaemonAPI.ConnectionProvider?
    @State private var disconnecting: DaemonAPI.Connection?
    /// The ended connection Connect Again\u{2026} is for, so its sheet opens the way it was made.
    @State private var again: DaemonAPI.Connection?

    var body: some View {
        Section {
            if let problem { Text(problem).tinted(.failure) }
            if let connections {
                if connections.isEmpty {
                    Text(ConnectorSetupWords.noConnections)
                        .foregroundStyle(.secondary)
                }
                ForEach(connections, id: \.provider) { c in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ConnectorSetupWords.connectionTitle(c)).fontWeight(.semibold)
                        Text(ConnectorSetupWords.connectionNote(c)).appText(.fine)
                            .tinted(c.state == .signInAgain ? .attention : .none).foregroundStyle(.secondary)
                    }
                    // The window's row actions (#1685).
                    if c.state == .signInAgain {
                        Button("Connect Again\u{2026}") { again = c; connecting = c.provider }
                    } else if c.provider == .github {
                        Link("Repositories on github.com", destination: URL(string: ConnectorSetupWords.installationsURL)!)
                    }
                    Button("Disconnect", role: .destructive) { disconnecting = c }
                }
                // A provider with no row; one that asks to connect again has its own button.
                if !has(.github, in: connections) {
                    Button(ConnectorSetupWords.connectButton) { again = nil; connecting = .github }
                }
                // Linear (#1343), GitLab (#1630) and Email (#1780): a row each while not connected.
                ForEach(others.filter { !has($0, in: connections) }) { p in
                    VStack(alignment: .leading, spacing: 2) {
                        Button("Connect \(ConnectorSetupWords.name(p))\u{2026}") { again = nil; connecting = p }
                        Text(ConnectorSetupWords.notConnectedNote(p)).appText(.fine).foregroundStyle(.secondary)
                    }
                }
            } else {
                ProgressView()
            }
        } header: {
            Text("Connections")
        }
        .paperListRow()
        .sheet(item: $connecting) { provider in
            if provider == .email {
                RemoteConnectEmailSheet(host: .mac, onConnected: { Task { await reload() } })
            } else {
                RemoteConnectSheet(provider: provider, host: .mac, again: again, onConnected: { Task { await reload() } })
            }
        }
        .confirmationDialog(disconnecting.map { "Disconnect \(ConnectorSetupWords.connectionTitle($0))?" } ?? "",
                            isPresented: Binding(get: { disconnecting != nil }, set: { if !$0 { disconnecting = nil } }),
                            titleVisibility: .visible) {
            Button("Disconnect", role: .destructive) {
                if let c = disconnecting { Task { await disconnect(c) } }
            }
        } message: {
            Text(disconnecting.map { ConnectorSetupWords.disconnectNote($0.provider) } ?? "")
        }
    }

    /// The providers after GitHub. Email only on a host that can sign in to a mailbox (#1780);
    /// an older host does not show it.
    private var others: [DaemonAPI.ConnectionProvider] {
        model.host(.mac, has: Capability.connectionsEmail1) ? [.linear, .gitlab, .email] : [.linear, .gitlab]
    }

    private func has(_ provider: DaemonAPI.ConnectionProvider, in list: [DaemonAPI.Connection]) -> Bool {
        list.contains { $0.provider == provider }
    }

    private func disconnect(_ c: DaemonAPI.Connection) async {
        disconnecting = nil
        let why = await model.disconnect(c.provider, on: .mac)
        await reload()
        if let why { problem = why }
    }
}

private extension View {
    /// The field's name above it, so a filled field still says what it is (#1799). The
    /// field's own title is its accessibility label, so VoiceOver skips the caption.
    func captioned(_ caption: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(caption).appText(.fine).foregroundStyle(.secondary).accessibilityHidden(true)
            self
        }
    }
}

extension RemoteModel {
    /// Where agents run (#2131): the machine the folder is on, and its line of what
    /// else is yours: the other machines and the providers.
    func whereAgentsRun(_ host: MachineRef) -> (title: String, line: String) {
        let others = folderHosts.filter { $0.id != host }.map(\.title)
        let providers = (machineProviders ?? []).map(\.name)
        return (WhereAgentsRun.title(onThisMac: false, hostName: hostLabel(host)),
                WhereAgentsRun.line(others: others, providers: providers))
    }
}
