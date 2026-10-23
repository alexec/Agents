import AgentsKitCore
import AppKit
import SwiftUI

/// A project's Connectors set-up (#1336, frames A, C, D and G): one Connect GitHub…, then four
/// slots (Tasks, Code review, CI, Where agents run), each proving itself with one real read,
/// then the events it turned on. The page is the set-up: Change… opens a slot in place, and
/// the only sheet is Connect. The state is the host's, so the Remote and the web page show
/// the same ticks.
struct ConnectorSetupView: View {
    @Environment(AppModel.self) private var model
    var project: ProjectKey
    var projectName: String
    /// Opens the catalogue (Add Connector…), for Linear and the others.
    var addConnector: () -> Void

    @State private var setup: DaemonAPI.ConnectorSetup?
    @State private var problem: String?
    @State private var reading = false
    @State private var changing: DaemonAPI.ConnectorSlotKind?
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

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Connectors").appText(.title).fontWeight(.semibold)
                Text(ConnectorSetupWords.intro(project: projectName, repository: setup?.repository,
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
                if setup.connection != nil || setup.events.state != .off {
                    heading("Events")
                    events(setup.events, forge: setup.forgeOrGitHub)
                }
            } else if problem == nil {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: project) { await load(.cached) }
        .task {
            control = ControlConfig.endpoint.flatMap { ControlSettingsModel(endpoint: $0) }
            await control?.refresh()
        }
        .sheet(item: $addingMachine, onDismiss: { Task { await control?.refresh() } }) { step in
            if let control { AddMachineSheet(control: control, start: step.start).paperSheet() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Back from github.com (an install, a grant): read again.
            Task { await load(.cached) }
        }
        .sheet(isPresented: $connecting) {
            if setup?.forgeOrGitHub == .gitlab {
                ConnectGitLabSheet(host: project.host, onConnected: { Task { await load(.fresh) } })
            } else {
                ConnectGitHubSheet(host: project.host, project: project, onConnected: { Task { await load(.fresh) } })
            }
        }
        .sheet(isPresented: $connectingLinear, onDismiss: {
            if linearConnected { linearConnected = false; addConnector() }
        }) {
            ConnectLinearSheet(host: project.host, onConnected: { linearConnected = true })
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
                SlotCard(slot: slot, setup: setup, projectName: projectName, place: place, reading: reading,
                         change: { changing = slot.slot }, act: act)
            }
        }
        if let changing, let slot = setup.slot(changing) {
            SlotChange(slot: slot, setup: setup, place: place, canAdd: control != nil,
                       act: act, done: { self.changing = nil })
        }
    }

    /// Where agents run (#2131): the machine the project's folder is on, and what else is yours.
    private var place: Place {
        let hosts = control?.hosts ?? []
        let here = model.isOnThisMac(project.host)
        let title = WhereAgentsRun.title(onThisMac: here, hostName: hosts.first { $0.id == project.host }?.name)
        let others = hosts.filter { $0.id != project.host && $0.runsAgents }
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
                            model.sidebarItem = .workflow(project.folder.path + "/" + workflow.id, in: project)
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
             addMachine, addProvider
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
        }
    }

    /// The Linear connector reads the person's Linear connection (#1682): without one, it
    /// has nothing to read, so the connection comes first.
    private func useLinear() async {
        if case .success(let list) = await model.connections(on: project.host),
           list.contains(where: { $0.provider == .linear && $0.state == .connected }) {
            addConnector()
        } else {
            connectingLinear = true
        }
    }

    private func load(_ how: DaemonAPI.ConnectorSetupReading) async {
        reading = true
        defer { reading = false }
        switch await model.connectorSetup(project, reading: how) {
        case .success(let fresh): setup = fresh; problem = nil
        case .failure(let failure): problem = failure.words
        }
    }

    private func skip(_ slot: DaemonAPI.ConnectorSlotKind, _ skipped: Bool) async {
        switch await model.skipConnectorSlot(project, slot, skipped: skipped) {
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
    let projectName: String
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
            actions
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
        .paperRaised(in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
    }

    private var canChange: Bool {
        slot.slot == .workspace || [.read, .refused, .failed].contains(slot.state)
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
                 : ConnectorSetupWords.line(slot, project: projectName, repository: setup.repository, forge: setup.forgeOrGitHub))
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
                skip
            case .noRemote:
                if slot.slot == .tasks {
                    Button("Linear\u{2026}") { act(.linear) }.buttonStyle(.paper)
                    Button("From a catalogue\u{2026}") { act(.catalogue) }.buttonStyle(.link)
                }
                skip
            case .failed:
                Button("Try Again") { act(.tryAgain) }.buttonStyle(.paper)
            case .refused:
                Button(ConnectorSetupWords.grantButton(setup)) { act(.open(ConnectorSetupWords.grantURL(setup))) }
                    .buttonStyle(.paper)
                Button("Try Again") { act(.tryAgain) }.buttonStyle(.paper)
            case .skipped:
                Button("Set Up") { act(.setUp(slot.slot)) }.buttonStyle(.link)
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
            return [
                Choice(title: place.title, note: WhereAgentsRun.hereNote, chosen: true, pick: done),
                Choice(title: AddMachine.Words.menuItem, note: canAdd ? WhereAgentsRun.addMachineNote : need, chosen: false,
                       pick: { if canAdd { act(.addMachine) } }),
                Choice(title: AddMachine.Words.addProvider, note: canAdd ? WhereAgentsRun.addProviderNote : need, chosen: false,
                       pick: { if canAdd { act(.addProvider) } }),
            ]
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
}
