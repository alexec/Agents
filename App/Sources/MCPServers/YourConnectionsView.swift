import AgentsKitCore
import AppKit
import SwiftUI

/// Activity ▸ Your Connectors (#1336, frame E): the person's connections, one row each with
/// Disconnect, and each project's set-up with Open ›. A connection is the person's, so it
/// lives here; a project's page shows it as one line.
struct YourConnectionsView: View {
    @Environment(AppModel.self) private var model

    @State private var connections: [DaemonAPI.Connection]?
    @State private var setups: [ProjectKey: DaemonAPI.ConnectorSetup] = [:]
    @State private var problem: String?
    @State private var connecting: DaemonAPI.ConnectionProvider?
    @State private var disconnecting: DaemonAPI.Connection?

    private var projects: [DaemonAPI.ProjectSummary] {
        model.work.projects.filter { $0.host == .mac && !$0.project.isArchived && $0.isChat != true }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Your Connectors").appText(.title).fontWeight(.semibold)
                Text("Your connections, and the connectors in your own ~/.agents/mcp.json. They reach every project.")
                    .appText(.supporting).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                heading("Connections")
                Spacer()
                if !unconnected.isEmpty {
                    Menu("Connect\u{2026}") { connectItems }
                        .menuStyle(.button).buttonStyle(.paper).fixedSize().appText(.fine)
                        // Under the paper style the menu button has no name and takes no press, so
                        // a plain menu stands in for it to VoiceOver and walks (#1799).
                        .accessibilityRepresentation { Menu("Connect\u{2026}") { connectItems } }
                }
            }
            if let problem {
                Text(problem).appText(.fine).tinted(.failure).fixedSize(horizontal: false, vertical: true)
            }
            card {
                if let connections, !connections.isEmpty {
                    ForEach(Array(connections.enumerated()), id: \.element.provider) { index, c in
                        if index > 0 { Divider().padding(.leading, 58) }
                        connectionRow(c)
                    }
                } else if connections != nil {
                    Text(ConnectorSetupWords.noConnections)
                        .appText(.supporting).foregroundStyle(.secondary)
                        .padding(.horizontal, 14).padding(.vertical, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ProgressView().controlSize(.small).padding(12)
                }
            }
            if !projects.isEmpty {
                heading("Projects").padding(.top, 6)
                card {
                    ForEach(Array(projects.enumerated()), id: \.element.id) { index, p in
                        if index > 0 { Divider().padding(.leading, 14) }
                        projectRow(p)
                    }
                }
            }
        }
        .task { await load() }
        .sheet(item: $connecting) { p in
            switch p {
            case .github: ConnectGitHubSheet(host: .mac, onConnected: { Task { await load() } })
            case .linear: ConnectLinearSheet(host: .mac, onConnected: { Task { await load() } })
            case .gitlab: ConnectGitLabSheet(host: .mac, onConnected: { Task { await load() } })
            case .email: ConnectEmailSheet(host: .mac, onConnected: { Task { await load() } })
            }
        }
        .confirmationDialog(disconnectTitle, isPresented: Binding(get: { disconnecting != nil },
                                                                   set: { if !$0 { disconnecting = nil } }),
                            titleVisibility: .visible) {
            Button("Disconnect", role: .destructive) {
                if let c = disconnecting { Task { await disconnect(c) } }
            }
        } message: {
            Text(disconnectMessage)
        }
    }

    private func heading(_ text: String) -> some View {
        Text(text).appText(.fine).fontWeight(.semibold).foregroundStyle(.secondary)
            .textCase(.uppercase)
            .accessibilityAddTraits(.isHeader)
    }

    private func card(@ViewBuilder _ content: () -> some View) -> some View {
        VStack(spacing: 0, content: content)
            .frame(maxWidth: .infinity, alignment: .leading)
            .paperRaised(in: RoundedRectangle(cornerRadius: 10))
    }

    private func connectionRow(_ c: DaemonAPI.Connection) -> some View {
        HStack(spacing: 12) {
            ConnectorMark(letters: String((c.login ?? ConnectorSetupWords.name(c.provider)).prefix(1)).uppercased())
            VStack(alignment: .leading, spacing: 2) {
                Text(ConnectorSetupWords.connectionTitle(c)).appText(.supporting).fontWeight(.semibold)
                Text(ConnectorSetupWords.connectionNote(c)).appText(.fine)
                    .tinted(c.state == .signInAgain ? .attention : .none)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if c.state == .signInAgain {
                Button("Connect Again\u{2026}") { connecting = c.provider }.buttonStyle(.paper).appText(.fine)
            } else if c.provider == .github {
                Button("Repositories on github.com") { open(ConnectorSetupWords.installationsURL) }
                    .buttonStyle(.link).appText(.fine)
            }
            Button("Disconnect") { disconnecting = c }
                .buttonStyle(.paper).appText(.fine).tinted(.failure)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private func projectRow(_ p: DaemonAPI.ProjectSummary) -> some View {
        let setup = setups[p.key]
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(p.name).appText(.supporting).fontWeight(.semibold)
                Text(setup.map(ConnectorSetupWords.projectLine) ?? " ").appText(.fine).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if let setup {
                Text("\(setup.done) of \(setup.slots.count)").appText(.fine).foregroundStyle(.secondary).monospacedDigit()
            }
            Button("Open \u{203A}") { model.sidebarItem = .projectMCPServers(p.key) }
                .buttonStyle(.link).appText(.fine)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    @ViewBuilder private var connectItems: some View {
        ForEach(unconnected, id: \.self) { p in
            Button(ConnectorSetupWords.name(p)) { connecting = p }
        }
    }

    /// The providers with no working connection, for Connect…. Email only on a host that can
    /// sign in to a mailbox (#1780); an older host does not show it.
    private var unconnected: [DaemonAPI.ConnectionProvider] {
        DaemonAPI.ConnectionProvider.allCases.filter { p in
            if p == .email, !model.host(.mac, has: Capability.connectionsEmail1) { return false }
            return connections?.contains(where: { $0.provider == p && $0.state == .connected }) != true
        }
    }

    private var disconnectTitle: String {
        disconnecting.map { "Disconnect \(ConnectorSetupWords.connectionTitle($0))?" } ?? ""
    }

    /// Which projects lose which slots, before it goes. Only GitHub fills a project's slots.
    private var disconnectMessage: String {
        guard let c = disconnecting else { return "" }
        if c.provider != .github { return ConnectorSetupWords.disconnectNote(c.provider) }
        let losing = projects.compactMap { p -> String? in
            guard let s = setups[p.key] else { return nil }
            let slots = s.slots.filter { $0.slot != .workspace && $0.state == .read }
                .map { ConnectorSetupWords.heading($0.slot) }
            return slots.isEmpty ? nil : "\(p.name) loses \(slots.joined(separator: ", "))."
        }
        return (losing + [ConnectorSetupWords.disconnectNote]).joined(separator: " ")
    }

    private func load() async {
        switch await model.connections(on: .mac) {
        case .success(let list): connections = list; problem = nil
        case .failure(let failure): connections = []; problem = failure.words
        }
        for p in projects {
            if case .success(let setup) = await model.connectorSetup(p.key, reading: .stored) { setups[p.key] = setup }
        }
    }

    private func disconnect(_ c: DaemonAPI.Connection) async {
        disconnecting = nil
        problem = await model.disconnect(c.provider, on: .mac)
        await load()
    }

    private func open(_ address: String) {
        guard let url = URL(string: address) else { return }
        NSWorkspace.shared.open(url) // store-ok: github.com in the browser, not a path
    }
}
