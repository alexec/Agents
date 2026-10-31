import AgentsKitCore
import AppKit
import SwiftUI

/// A folder's Connectors set-up (#1336, frames A, C, D and G): one Connect GitHub…, then four
/// slots (Tasks, Code review, CI, Where agents run), each proving itself with one real read,
/// then the events it turned on. The page is the set-up: Change… opens a slot in place, and
/// the only sheet is Connect. The state is the host's, so the Remote and the web page show
/// the same ticks.
struct ConnectorSetupView: View {
    @Environment(AppModel.self) private var model
    var folder: FolderKey
    var folderName: String
    /// Opens the catalogue (Add Connector…), for Linear and the others.
    var addConnector: () -> Void

    @State private var setup: DaemonAPI.ConnectorSetup?
    @State private var problem: String?
    @State private var reading = false
    @State private var changing: DaemonAPI.ConnectorSlotKind?
    @State private var codespaces: [DaemonAPI.ConnectorCodespace] = []
    @State private var codespacesProblem: String?
    @State private var codespacesFlow: CodespacesFlow?
    @State private var connecting = false
    /// Connect Linear, from the Tasks slot (#1682).
    @State private var connectingLinear = false
    /// Linear connected in that sheet: the catalogue opens next, for its connector.
    @State private var linearConnected = false
    /// The control plane, for Where agents run (#2131): the machines and providers, and Add a
    /// Machine… in place. Nil with none.
    @State private var control: ControlSettingsModel?
    @State private var addingMachine: Adding?

    /// Add a Machine… or Add Provider…, both the one sheet: Add Provider goes on to a machine.
    enum Adding: String, Identifiable {
        case machine, provider
        var id: String { rawValue }
        var start: AddMachineSheet.Step { self == .machine ? .choose : .addProvider }
    }

    enum CodespacesFlow: Identifiable {
        case choose
        case install(DaemonAPI.ConnectorCodespace)
        var id: String {
            switch self {
            case .choose: "choose"
            case .install(let codespace): "install/\(codespace.id)"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Connectors").appText(.title).fontWeight(.semibold)
                Text(ConnectorSetupWords.intro(folder: folderName, repository: setup?.repository,
                                               site: setup?.siteOrGitHub ?? "github.com"))
                    .appText(.supporting).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if let problem {
                Text(problem).appText(.fine).tinted(.failure).fixedSize(horizontal: false, vertical: true)
            }
            if let setup {
                connection(setup)
                heading(ConnectorSetupWords.setUpHeading(setup))
                slots(setup)
                ProjectSlotsCard(control: model.controlRequests, setup: setup) { await load(.cached) }
                if setup.connection != nil || setup.events.state != .off {
                    heading("Events")
                    events(setup.events, forge: setup.forgeOrGitHub)
                }
            } else if problem == nil {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: folder) { await load(.cached) }
        .task {
            control = ControlConfig.endpoint.flatMap { ControlSettingsModel(endpoint: $0) }
            await control?.refresh()
        }
        .sheet(item: $addingMachine, onDismiss: { Task { await control?.refresh() } }) { step in
            if let control { AddMachineSheet(control: control, start: step.start).paperSheet() }
        }
        .sheet(item: $codespacesFlow, onDismiss: {
            Task { await control?.refresh(); await loadCodespaces(.list) }
        }) { flow in
            switch flow {
            case .choose:
                CodespacesSheet(folder: folder, repository: setup?.repository ?? "", model: model, codespaces: codespaces,
                                problem: codespacesProblem, onChange: { codespaces = $0 },
                                onProblem: { codespacesProblem = $0 },
                                onConnect: { codespacesFlow = .install($0) },
                                onClose: { codespacesFlow = nil }).paperSheet()
            case .install(let codespace):
                if let control {
                ControlAddServerSheet(control: control,
                                          prefill: .init(destination: codespace.ssh, name: codespace.id,
                                                         tunnel: true, provider: nil, workspace: nil)).paperSheet()
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Back from github.com (an install, a grant): read again.
            Task { await load(.cached) }
        }
        .sheet(isPresented: $connecting) {
            if setup?.forgeOrGitHub == .gitlab {
                ConnectGitLabSheet(host: folder.host, onConnected: { Task { await load(.fresh) } })
            } else {
                ConnectGitHubSheet(host: folder.host, folder: folder, onConnected: { Task { await load(.fresh) } })
            }
        }
        .sheet(isPresented: $connectingLinear, onDismiss: {
            if linearConnected { linearConnected = false; addConnector() }
        }) {
            ConnectLinearSheet(host: folder.host, onConnected: { linearConnected = true })
        }
    }

    private func heading(_ text: String) -> some View {
        Text(text).appText(.fine).fontWeight(.semibold).foregroundStyle(.secondary)
            .textCase(.uppercase)
            .padding(.top, 6)
            .accessibilityAddTraits(.isHeader)
    }

    // MARK: The connection

    @ViewBuilder private func connection(_ setup: DaemonAPI.ConnectorSetup) -> some View {
        if let c = setup.connection, c.state == .connected {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    ConnectorMark(letters: String((c.login ?? "G").prefix(1)).uppercased())
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ConnectorSetupWords.connected(c)).appText(.supporting).fontWeight(.semibold)
                        Text(ConnectorSetupWords.connectedNote(setup)).appText(.fine).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Button("Manage in Connectors\u{2026}") { model.sidebarItem = .mcpServers }
                        .buttonStyle(.link).appText(.fine)
                }
                if setup.installed == false, let repository = setup.repository {
                    HStack(spacing: 6) {
                        Text(ConnectorSetupWords.notInstalled(repository)).appText(.fine).tinted(.attention)
                        Button("Install on github.com") { open(setup.installURL ?? ConnectorSetupWords.installURL) }
                            .buttonStyle(.link).appText(.fine)
                    }
                }
            }
            .padding(14)
            .paperRaised(in: RoundedRectangle(cornerRadius: 10))
        } else {
            HStack(spacing: 12) {
                ConnectorMark(letters: ConnectorSetupWords.letters(setup.forgeOrGitHub), filled: true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(setup.connection?.state == .signInAgain ? ConnectorSetupWords.connectAgain(setup.forgeOrGitHub)
                         : ConnectorSetupWords.connectTitle(setup.forgeOrGitHub))
                        .appText(.supporting).fontWeight(.semibold)
                    Text(ConnectorSetupWords.connectNote(setup.forgeOrGitHub)).appText(.fine).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button(ConnectorSetupWords.connectButton(setup.forgeOrGitHub)) { connecting = true }
                    .buttonStyle(.paperProminent)
            }
            .padding(14)
            .paperRaised(in: RoundedRectangle(cornerRadius: 10))
        }
    }

    // MARK: The slots

    private let columns = [GridItem(.adaptive(minimum: 230), spacing: 12, alignment: .top)]

    @ViewBuilder private func slots(_ setup: DaemonAPI.ConnectorSetup) -> some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
            ForEach(setup.slots.filter { $0.slot != changing }) { slot in
                SlotCard(slot: slot, setup: setup, folderName: folderName, place: place, reading: reading,
                         change: { changing = slot.slot }, act: act)
            }
        }
        if let changing, let slot = setup.slot(changing) {
            SlotChange(slot: slot, setup: setup, place: place, canAdd: control != nil,
                       codespaces: codespaces, codespacesProblem: codespacesProblem,
                       act: act, done: { self.changing = nil })
        }
    }

    /// Where agents run (#2131): the machine the folder is on, and what else is yours.
    private var place: Place {
        let hosts = control?.hosts ?? []
        let here = model.isOnThisMac(folder.host)
        let title = WhereAgentsRun.title(onThisMac: here, hostName: hosts.first { $0.id == folder.host }?.name)
        let others = hosts.filter { $0.id != folder.host && $0.runsAgents }
            .map { $0.id == control?.thisMacHost?.id ? "This Mac" : $0.name }
        return Place(title: title, line: WhereAgentsRun.line(others: others, providers: control?.providers.map(\.name) ?? []))
    }

    struct Place {
        var title: String
        var line: String
    }

    // MARK: The events

    private func events(_ events: DaemonAPI.ConnectorEvents, forge: DaemonAPI.ConnectionProvider) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(ConnectorSetupWords.eventsLead(events, forge: forge)).appText(.supporting)
                    .fixedSize(horizontal: false, vertical: true)
                if events.state == .on {
                    Text(ConnectorSetupWords.eventNouns(events.names).joined(separator: " "))
                        .appText(.code).foregroundStyle(Paper.accent)
                        .help(events.names.joined(separator: ", "))
                }
            }
            if events.state == .on {
                HStack(spacing: 4) {
                    Text(ConnectorSetupWords.workflowsLead(events)).appText(.fine).foregroundStyle(.secondary)
                    ForEach(Array(events.workflows.enumerated()), id: \.element.id) { index, workflow in
                        Button(workflow.name + (index < events.workflows.count - 1 ? "," : ".")) {
                            model.sidebarItem = .workflow(folder.folder.path + "/" + workflow.id, in: folder)
                        }
                        .buttonStyle(.link).appText(.fine)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .paperRaised(in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: Acting

    enum Action {
        case connect, tryAgain, skip(DaemonAPI.ConnectorSlotKind), setUp(DaemonAPI.ConnectorSlotKind), catalogue, open(String),
             addMachine, addProvider, codespaces
        /// Linear for Tasks: Connect Linear first when it is not connected, then the catalogue.
        case linear
    }

    private func act(_ action: Action) {
        switch action {
        case .connect: connecting = true
        case .tryAgain: Task { await load(.fresh) }
        case .skip(let slot): Task { await skip(slot, true) }
        case .setUp(let slot): Task { await skip(slot, false) }
        case .catalogue: addConnector()
        case .linear: Task { await useLinear() }
        case .open(let address): open(address)
        case .addMachine: addingMachine = .machine
        case .addProvider: addingMachine = .provider
        case .codespaces: codespacesFlow = .choose
        }
    }

    /// The Linear connector reads the person's Linear connection (#1682): without one, it
    /// has nothing to read, so the connection comes first.
    private func useLinear() async {
        if case .success(let list) = await model.connections(on: folder.host),
           list.contains(where: { $0.provider == .linear && $0.state == .connected }) {
            addConnector()
        } else {
            connectingLinear = true
        }
    }

    private func load(_ how: DaemonAPI.ConnectorSetupReading) async {
        reading = true
        defer { reading = false }
        switch await model.connectorSetup(folder, reading: how) {
        case .success(let fresh):
            setup = fresh; problem = nil
            if fresh.forgeOrGitHub == .github, fresh.connection?.state == .connected, fresh.repository != nil {
                await loadCodespaces(.list)
            } else {
                codespaces = []; codespacesProblem = nil
            }
        case .failure(let failure): problem = failure.words
        }
    }

    private func loadCodespaces(_ action: DaemonAPI.ConnectorCodespacesRequest.Action) async {
        guard setup?.forgeOrGitHub == .github, setup?.repository != nil else { return }
        switch await model.codespaces(folder, action: action) {
        case .success(let result): codespaces = result.codespaces; codespacesProblem = result.message
        case .failure(let failure): codespacesProblem = failure.words
        }
    }

    private func skip(_ slot: DaemonAPI.ConnectorSlotKind, _ skipped: Bool) async {
        switch await model.skipConnectorSlot(folder, slot, skipped: skipped) {
        case .success(let fresh): setup = fresh; problem = nil; changing = nil
        case .failure(let failure): problem = failure.words
        }
    }

    private func open(_ address: String) {
        guard let url = URL(string: address) else { return }
        NSWorkspace.shared.open(url) // store-ok: github.com in the browser, not a path
    }
}

/// One slot (frames A, C and G): its mark, its name, the one thing it read, and what can be
/// done from here.
private struct SlotCard: View {
    let slot: DaemonAPI.ConnectorSlot
    let setup: DaemonAPI.ConnectorSetup
    let folderName: String
    let place: ConnectorSetupView.Place
    let reading: Bool
    let change: () -> Void
    let act: (ConnectorSetupView.Action) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                SlotMark(state: slot.state, reading: reading)
                Text(ConnectorSetupWords.heading(slot.slot)).appText(.fine).fontWeight(.semibold)
                    .foregroundStyle(.secondary).textCase(.uppercase)
                Spacer(minLength: 4)
                if canChange {
                    Button("Change\u{2026}", action: change).buttonStyle(.link).appText(.fine)
                }
            }
            Text(slot.slot == .workspace ? place.title : ConnectorSetupWords.title(slot))
                .appText(.supporting).fontWeight(.semibold)
            proofOrLine
            if slot.isFromProject {
                // The project's (#2669): changed in the project's card, not here.
                Text(ProjectWords.setByProject(setup.projectName ?? ProjectWords.title))
                    .appText(.fine).foregroundStyle(.secondary)
            }
            actions
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
        .paperRaised(in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
    }

    private var canChange: Bool {
        slot.slot == .workspace || (!slot.isFromProject && [.read, .refused, .failed].contains(slot.state))
    }

    @ViewBuilder private var proofOrLine: some View {
        if let proof = slot.proof {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(ConnectorSetupWords.proofLead(slot.slot) + ":").foregroundStyle(.secondary)
                if let number = proof.number {
                    if let url = proof.url {
                        Button("#\(number)") { act(.open(url)) }.buttonStyle(.link)
                    } else {
                        Text("#\(number)")
                    }
                }
                Text(ConnectorSetupWords.proofText(proof)).foregroundStyle(.secondary).lineLimit(2)
            }
            .appText(.fine)
            .accessibilityElement(children: .combine)
        } else {
            Text(slot.slot == .workspace ? place.line
                 : ConnectorSetupWords.line(slot, folder: folderName, repository: setup.repository, forge: setup.forgeOrGitHub))
                .appText(.fine)
                .tinted([.failed, .refused, .noRemote].contains(slot.state) ? .attention : .none)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var actions: some View {
        let skip = Button("Skip") { act(.skip(slot.slot)) }.buttonStyle(.link).foregroundStyle(.secondary)
        HStack(spacing: 10) {
            switch slot.state {
            case .notConnected:
                if slot.slot == .tasks {
                    Button("Use Linear instead\u{2026}") { act(.linear) }.buttonStyle(.link)
                }
                if !slot.isFromProject { skip }
            case .noRemote:
                if slot.slot == .tasks {
                    Button("Linear\u{2026}") { act(.linear) }.buttonStyle(.paper)
                    Button("From a catalogue\u{2026}") { act(.catalogue) }.buttonStyle(.link)
                }
                if !slot.isFromProject { skip }
            case .failed:
                Button("Try Again") { act(.tryAgain) }.buttonStyle(.paper)
            case .refused:
                Button(ConnectorSetupWords.grantButton(setup)) { act(.open(ConnectorSetupWords.grantURL(setup))) }
                    .buttonStyle(.paper)
                Button("Try Again") { act(.tryAgain) }.buttonStyle(.paper)
            case .skipped where !slot.isFromProject:
                Button("Set Up") { act(.setUp(slot.slot)) }.buttonStyle(.link)
            case .skipped:
                EmptyView()
            case .read, .notRead:
                EmptyView()
            }
        }
        .appText(.fine)
        .padding(.top, 2)
    }
}

/// The slot's mark: a tick once it read, an open circle while it waits, a dashed one when
/// skipped, an exclamation when the read did not work.
private struct SlotMark: View {
    let state: DaemonAPI.ConnectorSlotState
    let reading: Bool

    var body: some View {
        Group {
            switch state {
            case .read:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Paper.accent)
            case .failed, .refused:
                Image(systemName: "exclamationmark.circle").tinted(.attention)
            case .skipped:
                Circle().strokeBorder(style: StrokeStyle(lineWidth: 1.2, dash: [2.5, 2])).foregroundStyle(.secondary)
                    .frame(width: 13, height: 13)
            case .notRead where reading:
                ProgressView().controlSize(.mini)
            case .notConnected, .noRemote, .notRead:
                Image(systemName: "circle").foregroundStyle(.secondary)
            }
        }
        .appText(.fine)
        .frame(width: 15, height: 15)
        // One element with one label: a label stacked over the image's own recurses (#71).
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }

    private var label: String {
        switch state {
        case .read: "Read"
        case .failed: "Couldn't read"
        case .refused: "Refused"
        case .skipped: "Skipped"
        case .notRead: "Reading"
        case .notConnected: "Not connected"
        case .noRemote: ConnectorSetupWords.noRemote
        }
    }
}

/// A slot opened in place (frame D): its choices, with no sheet.
private struct SlotChange: View {
    let slot: DaemonAPI.ConnectorSlot
    let setup: DaemonAPI.ConnectorSetup
    let place: ConnectorSetupView.Place
    /// A control plane to add a machine or provider to.
    let canAdd: Bool
    let codespaces: [DaemonAPI.ConnectorCodespace]
    let codespacesProblem: String?
    let act: (ConnectorSetupView.Action) -> Void
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                SlotMark(state: slot.state, reading: false)
                Text(ConnectorSetupWords.heading(slot.slot)).appText(.fine).fontWeight(.semibold)
                    .foregroundStyle(.secondary).textCase(.uppercase)
            }
            Text(question).appText(.supporting).fontWeight(.semibold)
            HStack(alignment: .top, spacing: 10) {
                ForEach(choices, id: \.title) { choice in
                    Button(action: choice.pick) {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: choice.chosen ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(choice.chosen ? Paper.accent : .secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(choice.title).appText(.supporting).fontWeight(.semibold)
                                Text(choice.note).appText(.fine).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .contentShape(Rectangle())
                        .overlay(RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(choice.chosen ? Paper.accent : Paper.rule, lineWidth: choice.chosen ? 2 : 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(choice.chosen ? .isSelected : [])
                }
            }
            HStack {
                Button("Done", action: done).buttonStyle(.paper).keyboardShortcut(.cancelAction)
            }
            .appText(.fine)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Paper.raised, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Paper.accent, lineWidth: 2))
    }

    private struct Choice {
        var title: String
        var note: String
        var chosen: Bool
        var pick: () -> Void
    }

    private var question: String {
        switch slot.slot {
        case .tasks: "Where do agents find their tasks?"
        case .codeReview: "Where do agents ask for review?"
        case .ci: "Where do agents see checks?"
        case .workspace: "Where should agents run?"
        }
    }

    private var choices: [Choice] {
        let skipped = slot.state == .skipped
        switch slot.slot {
        case .workspace:
            // With no control plane the two adds say what they need, and do nothing (#2131).
            let need = AddMachine.Words.needsControlPlane
            var choices = [
                Choice(title: place.title, note: WhereAgentsRun.hereNote, chosen: true, pick: done),
                Choice(title: AddMachine.Words.menuItem, note: canAdd ? WhereAgentsRun.addMachineNote : need, chosen: false,
                       pick: { if canAdd { act(.addMachine) } }),
                Choice(title: AddMachine.Words.addProvider, note: canAdd ? WhereAgentsRun.addProviderNote : need, chosen: false,
                       pick: { if canAdd { act(.addProvider) } }),
            ]
            if canAdd, setup.forgeOrGitHub == .github, setup.repository != nil, setup.connection?.state == .connected {
                let note = codespacesProblem ?? codespacesSummary
                choices.insert(Choice(title: "GitHub Codespaces…", note: note, chosen: false,
                                      pick: { act(.codespaces) }), at: 1)
            }
            return choices
        case .tasks:
            return [
                Choice(title: slot.choice, note: ConnectorSetupWords.proof(slot) ?? ConnectorSetupWords.comesWith(setup.forgeOrGitHub),
                       chosen: !skipped, pick: { if skipped { act(.setUp(.tasks)) }; done() }),
                Choice(title: "Linear\u{2026}", note: "Connect Linear, then add its connector.", chosen: false,
                       pick: { act(.linear) }),
                Choice(title: "From a catalogue\u{2026}", note: "Another tracker's connector.", chosen: false,
                       pick: { act(.catalogue) }),
                Choice(title: "None", note: "Skip: agents won't use a tracker here.", chosen: skipped,
                       pick: { act(.skip(.tasks)) }),
            ]
        case .codeReview, .ci:
            return [
                Choice(title: slot.choice, note: ConnectorSetupWords.proof(slot) ?? ConnectorSetupWords.comesWith(setup.forgeOrGitHub),
                       chosen: !skipped, pick: { if skipped { act(.setUp(slot.slot)) }; done() }),
                Choice(title: "From a catalogue\u{2026}", note: "Another tool's connector.", chosen: false,
                       pick: { act(.catalogue) }),
                Choice(title: "None", note: "Skip it here.", chosen: skipped, pick: { act(.skip(slot.slot)) }),
            ]
        }
    }

    private var codespacesSummary: String {
        switch codespaces.count {
        case 0: return "Read just now: no Codespaces"
        case 1:
            let one = codespaces[0]
            return "Read just now: 1 Codespace, \(one.state.lowercased())"
        default:
            return "Read just now: \(codespaces.count) Codespaces"
        }
    }
}

/// Codespaces from the GitHub connection, reached from the folder's Where agents run slot.
private struct CodespacesSheet: View {
    let folder: FolderKey
    let repository: String
    let model: AppModel
    let codespaces: [DaemonAPI.ConnectorCodespace]
    let problem: String?
    let onChange: ([DaemonAPI.ConnectorCodespace]) -> Void
    let onProblem: (String?) -> Void
    let onConnect: (DaemonAPI.ConnectorCodespace) -> Void
    let onClose: () -> Void

    @State private var displayName = ""
    @State private var working = false
    @State private var confirmingCreate = false
    @State private var confirmingStart = false
    @State private var pendingStart: DaemonAPI.ConnectorCodespace?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("GitHub Codespaces").appText(.title).fontWeight(.semibold)
            Text("Use a Codespace for this folder, or create one from \(repository). Connect over SSH; Agents installs on the Codespace.")
                .appText(.supporting).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("Connect prepares the Codespaces entries in ~/.ssh/config with GitHub CLI.")
                .appText(.fine).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("GitHub CLI must be signed in as the connected GitHub account.")
                .appText(.fine).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let problem {
                Text(problem).appText(.fine).tinted(.failure).fixedSize(horizontal: false, vertical: true)
            }
            if codespaces.isEmpty {
                Text("No Codespaces for this repository yet.").appText(.supporting).foregroundStyle(.secondary)
            }
            ForEach(codespaces) { codespace in
                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(codespace.name).appText(.supporting).fontWeight(.semibold)
                        Text("\(codespace.state) · \(codespace.ref ?? codespace.repository)")
                            .appText(.fine).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Button(isRunning(codespace) ? "Stop" : (isStarting(codespace) ? "Starting…" : "Start")) {
                        startOrStop(codespace)
                    }
                    .buttonStyle(.link).disabled(working || isStarting(codespace))
                    Button(isRunning(codespace) ? "Connect over SSH" : "Start to connect") { connectOrStart(codespace) }
                        .buttonStyle(.paper).disabled(working || isStarting(codespace))
                }
                .padding(10)
                .paperRaised(in: RoundedRectangle(cornerRadius: 8))
            }
            HStack(spacing: 8) {
                TextField("Codespace name", text: $displayName, prompt: Text("Folder name"))
                    .textFieldStyle(.roundedBorder)
                    .disabled(working)
                Button("Create…") { confirmingCreate = true }
                    .buttonStyle(.paperProminent).disabled(working || displayName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            HStack {
                if working { ProgressView().controlSize(.small) }
                Spacer()
                Button("Refresh") { Task { await refresh() } }.buttonStyle(.link).disabled(working)
                Button("Done", action: onClose).buttonStyle(.paper).keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 660)
        .confirmationDialog("Create a Codespace?", isPresented: $confirmingCreate, titleVisibility: .visible) {
            Button("Create Codespace") { Task { await create() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("GitHub may charge for Codespaces compute. The Codespace will use \(repository).")
        }
        .confirmationDialog("Start a Codespace?", isPresented: $confirmingStart, titleVisibility: .visible) {
            Button("Start Codespace") {
                if let pendingStart { Task { await start(pendingStart) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("GitHub may charge while \(pendingStart?.name ?? "this Codespace") runs.")
        }
    }

    private func isRunning(_ codespace: DaemonAPI.ConnectorCodespace) -> Bool {
        ["available", "running"].contains(codespace.state.lowercased())
    }

    private func isStarting(_ codespace: DaemonAPI.ConnectorCodespace) -> Bool {
        ["starting", "provisioning", "queued", "awaiting", "rebuilding"].contains(codespace.state.lowercased())
    }

    private func refresh() async {
        working = true
        defer { working = false }
        switch await model.codespaces(folder, action: .list) {
        case .success(let result): onChange(result.codespaces); onProblem(result.message)
        case .failure(let failure): onProblem(failure.words)
        }
    }

    private func change(_ codespace: DaemonAPI.ConnectorCodespace, action: DaemonAPI.ConnectorCodespacesRequest.Action) async {
        working = true
        defer { working = false }
        switch await model.codespaces(folder, action: action, id: codespace.id) {
        case .success(let result): onChange(result.codespaces); onProblem(result.message)
        case .failure(let failure): onProblem(failure.words)
        }
    }

    private func create() async {
        working = true
        defer { working = false }
        switch await model.codespaces(folder, action: .create, name: displayName.trimmingCharacters(in: .whitespaces)) {
        case .success(let result): onChange(result.codespaces); onProblem(result.message); displayName = ""
        case .failure(let failure): onProblem(failure.words)
        }
    }

    private func startOrStop(_ codespace: DaemonAPI.ConnectorCodespace) {
        if isRunning(codespace) || isStarting(codespace) {
            Task { await change(codespace, action: .stop) }
        } else {
            pendingStart = codespace
            confirmingStart = true
        }
    }

    private func connectOrStart(_ codespace: DaemonAPI.ConnectorCodespace) {
        if isRunning(codespace) {
            Task { await prepareSSH(codespace) }
        } else {
            pendingStart = codespace
            confirmingStart = true
        }
    }

    private func start(_ codespace: DaemonAPI.ConnectorCodespace) async {
        confirmingStart = false
        pendingStart = nil
        working = true
        defer { working = false }
        switch await model.codespaces(folder, action: .start, id: codespace.id) {
        case .success(let result):
            onChange(result.codespaces); onProblem(result.message)
        case .failure(let failure): onProblem(failure.words)
        }
    }

    private func prepareSSH(_ codespace: DaemonAPI.ConnectorCodespace) async {
        working = true
        defer { working = false }
        switch await model.codespaces(folder, action: .prepareSSH) {
        case .success(let result):
            onChange(result.codespaces)
            onConnect(result.codespaces.first(where: { $0.id == codespace.id }) ?? codespace)
        case .failure(let failure): onProblem(failure.words)
        }
    }
}
