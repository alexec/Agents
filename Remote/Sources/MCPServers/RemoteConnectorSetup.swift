import AgentsKitCore
import SwiftUI

/// A project's Connectors set-up on the iPhone and iPad (#1336, frame F): the same page as
/// the window's, in the same order, with the slots as a list. Each slot opens its own screen
/// with its proof and its choices. The state is the host's, so all three clients show the
/// same ticks. Other providers are set up on the Mac (Providers is the Mac's own page).
struct RemoteConnectorSetup: View {
    @Environment(RemoteModel.self) private var model
    let project: ProjectKey
    let projectName: String
    @Binding var setup: DaemonAPI.ConnectorSetup?

    @State private var problem: String?
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
            Text(ConnectorSetupWords.intro(project: projectName, repository: setup?.repository))
        }
        .task(id: project) { await load(.cached) }
        .sheet(isPresented: $connecting) {
            RemoteConnectSheet(host: project.host, project: project, onConnected: { Task { await load(.fresh) } })
        }
        if let setup {
            Section(ConnectorSetupWords.setUpHeading(setup)) {
                ForEach(setup.slots) { slot in
                    NavigationLink {
                        RemoteSlotView(project: project, projectName: projectName, kind: slot.slot, setup: $setup)
                    } label: {
                        RemoteSlotRow(slot: slot, setup: setup, projectName: projectName)
                    }
                    .paperListRow()
                }
            }
            if setup.connection != nil || setup.events.state != .off {
                Section("Events") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(ConnectorSetupWords.eventsLead(setup.events))
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
                Text(setup.connection?.state == .signInAgain ? "GitHub asks you to connect again."
                     : ConnectorSetupWords.connectTitle)
                    .appText(.supporting).fontWeight(.semibold)
                Spacer(minLength: 8)
                Button(ConnectorSetupWords.connectButton) { connecting = true }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private func load(_ how: DaemonAPI.ConnectorSetupReading) async {
        switch await model.connectorSetup(project, reading: how) {
        case .success(let fresh): setup = fresh; problem = nil
        case .failure(let failure): problem = failure.words
        }
    }
}

/// One slot in the list: its mark, "Tasks · GitHub Issues", and one grey line.
private struct RemoteSlotRow: View {
    let slot: DaemonAPI.ConnectorSlot
    let setup: DaemonAPI.ConnectorSetup
    let projectName: String

    var body: some View {
        HStack(spacing: 12) {
            RemoteSlotMark(state: slot.state)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(ConnectorSetupWords.heading(slot.slot)) \u{00B7} \(ConnectorSetupWords.title(slot))")
                Text(subtitle).appText(.fine).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String {
        if let proof = ConnectorSetupWords.proof(slot) { return proof }
        if slot.state == .notConnected, slot.slot != .workspace { return "Comes with GitHub" }
        if slot.slot == .workspace, slot.state == .read { return ConnectorSetupWords.otherProvidersElsewhere }
        return ConnectorSetupWords.line(slot, project: projectName, repository: setup.repository)
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
    let project: ProjectKey
    let projectName: String
    let kind: DaemonAPI.ConnectorSlotKind
    @Binding var setup: DaemonAPI.ConnectorSetup?
    @State private var problem: String?

    private var slot: DaemonAPI.ConnectorSlot? { setup?.slot(kind) }

    var body: some View {
        List {
            if let slot, let setup {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            RemoteSlotMark(state: slot.state)
                            Text(ConnectorSetupWords.title(slot)).appText(.reading).fontWeight(.semibold)
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
                            Text(slot.slot == .workspace && slot.state == .read ? ConnectorSetupWords.otherProvidersElsewhere
                                 : ConnectorSetupWords.line(slot, project: projectName, repository: setup.repository))
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
                            Button("Grant on github.com") {
                                openURL(URL(string: setup.installURL ?? ConnectorSetupWords.installURL)!)
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
                            Text("Linear and other trackers: Add Connector on the Mac.")
                                .appText(.fine).foregroundStyle(.secondary)
                        }
                    } else {
                        Text(ConnectorSetupWords.otherProvidersElsewhere).foregroundStyle(.secondary)
                    }
                }
                .paperListRow()
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Paper.ground)
        .navigationTitle(ConnectorSetupWords.heading(kind))
    }

    private func skip(_ skipped: Bool) async {
        switch await model.skipConnectorSlot(project, kind, skipped: skipped) {
        case .success(let fresh): setup = fresh; problem = nil
        case .failure(let failure): problem = failure.words
        }
    }

    private func reload() async {
        switch await model.connectorSetup(project, reading: .fresh) {
        case .success(let fresh): setup = fresh; problem = nil
        case .failure(let failure): problem = failure.words
        }
    }
}

/// Connect GitHub on the iPhone and iPad (frame B): the host's device flow. The sheet shows
/// the code, copies it, opens github.com/login/device in Safari, waits, and closes by itself.
struct RemoteConnectSheet: View {
    @Environment(RemoteModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    let host: HostID
    var project: ProjectKey?
    var onConnected: () -> Void = {}

    private enum Step: Equatable {
        case asking, starting
        case waiting(DaemonAPI.ConnectionSignIn)
        case install(login: String, repository: String)
        case failed(String)
    }

    @State private var step: Step = .asking

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(ConnectorSetupWords.sheetSubtitle).foregroundStyle(.secondary)
                }
                .paperListRow()
                Section("Agents will be able to") {
                    ForEach(ConnectorSetupWords.abilities, id: \.self) { Text($0) }
                }
                .paperListRow()
                Section {
                    switch step {
                    case .asking:
                        Button(ConnectorSetupWords.continueButton) { Task { await start() } }.fontWeight(.semibold)
                    case .starting:
                        ProgressView()
                    case .waiting(let flow):
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Your code").appText(.fine).foregroundStyle(.secondary)
                            Text(flow.userCode).appText(.title).monospaced().fontWeight(.semibold).textSelection(.enabled)
                            Text(ConnectorSetupWords.sheetStatus(flow)).appText(.fine)
                        }
                        Button("Copy Code") { UIPasteboard.general.string = flow.userCode }
                        Button("Open github.com Again") { open(flow.verificationURL) }
                    case .install(let login, let repository):
                        Text("Connected as \(login).").fontWeight(.semibold)
                        Text(ConnectorSetupWords.notInstalled(repository)).appText(.fine)
                        Button("Install on github.com") { open(ConnectorSetupWords.installURL); dismiss() }
                    case .failed(let why):
                        Text(why).tinted(.failure)
                        Button("Try Again") { Task { await start() } }
                    }
                } footer: {
                    Text(ConnectorSetupWords.sheetChoose + " " + ConnectorSetupWords.sheetFoot)
                }
                .paperListRow()
            }
            .scrollContentBackground(.hidden)
            .background(Paper.ground)
            .navigationTitle("Connect GitHub")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(isInstall ? "Done" : "Cancel") { Task { await cancel() } }
                }
            }
        }
        .onDisappear {
            if case .waiting(let flow) = step { Task { await model.cancelSignIn(flow.flowID, on: host) } }
        }
    }

    private var isInstall: Bool { if case .install = step { true } else { false } }

    private func start() async {
        step = .starting
        let started: DaemonAPI.ConnectionSignIn
        switch await model.startSignIn(.github, on: host) {
        case .success(let flow): started = flow
        case .failure(let problem): step = .failed(problem.words); return
        }
        step = .waiting(started)
        UIPasteboard.general.string = started.userCode
        open(started.verificationURL)
        while case .waiting(let shown) = step, shown.flowID == started.flowID {
            let flow: DaemonAPI.ConnectionSignIn
            switch await model.waitForSignIn(started.flowID, on: host) {
            case .failure(let problem): step = .failed(problem.words); return
            case .success(let now): flow = now
            }
            switch flow.status {
            case .waiting: continue
            case .connected:
                step = .starting
                onConnected()
                if let project, case .success(let setup) = await model.connectorSetup(project, reading: .fresh),
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

/// Your Connectors ▸ Connections on the iPhone and iPad (frame E).
struct RemoteConnections: View {
    @Environment(RemoteModel.self) private var model
    @State private var connections: [DaemonAPI.Connection]?
    @State private var problem: String?
    @State private var connecting = false
    @State private var disconnecting: DaemonAPI.Connection?

    var body: some View {
        Section {
            if let problem { Text(problem).tinted(.failure) }
            if let connections {
                if connections.isEmpty {
                    Text("No connections yet. Connect GitHub to give agents issues, pull requests and Actions in every project.")
                        .foregroundStyle(.secondary)
                }
                ForEach(connections, id: \.provider) { c in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ConnectorSetupWords.connectionTitle(c)).fontWeight(.semibold)
                        Text(ConnectorSetupWords.connectionNote(c)).appText(.fine)
                            .tinted(c.state == .signInAgain ? .attention : .none).foregroundStyle(.secondary)
                    }
                    Button("Disconnect", role: .destructive) { disconnecting = c }
                }
                if !connections.contains(where: { $0.provider == .github && $0.state == .connected }) {
                    Button(ConnectorSetupWords.connectButton) { connecting = true }
                }
            } else {
                ProgressView()
            }
        } header: {
            Text("Connections")
        }
        .paperListRow()
        .task { await load() }
        .sheet(isPresented: $connecting) {
            RemoteConnectSheet(host: .mac, onConnected: { Task { await load() } })
        }
        .confirmationDialog(disconnecting.map { "Disconnect \(ConnectorSetupWords.connectionTitle($0))?" } ?? "",
                            isPresented: Binding(get: { disconnecting != nil }, set: { if !$0 { disconnecting = nil } }),
                            titleVisibility: .visible) {
            Button("Disconnect", role: .destructive) {
                if let c = disconnecting { Task { await disconnect(c) } }
            }
        } message: {
            Text(ConnectorSetupWords.disconnectNote)
        }
    }

    private func load() async {
        switch await model.connections(on: .mac) {
        case .success(let list): connections = list; problem = nil
        case .failure(let failure): connections = []; problem = failure.words
        }
    }

    private func disconnect(_ c: DaemonAPI.Connection) async {
        disconnecting = nil
        problem = await model.disconnect(c.provider, on: .mac)
        await load()
    }
}
