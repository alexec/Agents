import AgentsKitCore
import AppKit
import SwiftUI

/// MCP servers in `~/.agents/mcp.json` or a project's `.agents/mcp.json` (060).
/// The same rows in Settings and on a project's configuration page.
struct ProjectMCPSection: View {
    @Environment(AppModel.self) private var model
    var place: AgentsPlace

    @State private var servers: [DaemonAPI.ProjectMCPServer] = []
    @State private var problem: String?
    @State private var approvalsProblem: String?
    @State private var file = ""
    @State private var adding = false
    @State private var failure: String?

    var body: some View {
        heading
        Text(place.mcpNote)
            .appText(.fine).foregroundStyle(.secondary)
            .padding(.leading, 2)
            .padding(.bottom, 4)
        if let problem {
            Text(problem)
                .appText(.supporting).foregroundStyle(SharedInk.attention)
                .padding(.horizontal, 16).padding(.vertical, 13)
                .frame(maxWidth: .infinity, alignment: .leading)
                .paperRow()
        } else if servers.isEmpty {
            Text(place == .you ? "No MCP servers of your own yet." : "No MCP servers in this project yet.")
                .appText(.supporting).foregroundStyle(.secondary)
                .padding(.horizontal, 16).padding(.vertical, 13)
                .frame(maxWidth: .infinity, alignment: .leading)
                .paperRow()
        } else {
            if let approvalsProblem {
                Text(approvalsProblem).appText(.fine).foregroundStyle(SharedInk.attention)
            }
            if let failure {
                Text(failure).appText(.fine).foregroundStyle(SharedInk.attention)
            }
            ForEach(servers) { server in
                ProjectMCPRow(server: server, servers: servers, place: place, file: file,
                              changed: { Task { await load() } },
                              failed: { failure = $0 })
            }
        }
        Color.clear.frame(height: 0)
            .task(id: place) { await load() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                Task { await load() }
            }
            .sheet(isPresented: $adding) {
                AddMCPSheet(destination: place.destination, onAdded: { Task { await load() } })
            }
    }

    private var heading: some View {
        HStack(spacing: 8) {
            SectionHeading(title: "MCP servers")
                .fixedSize()
            if !servers.isEmpty {
                SharedChip(text: "\(servers.count)").padding(.top, 20)
            }
            Spacer()
            Group {
                Button("Reveal mcp.json") {
                    SharedFiles.reveal(file.isEmpty ? revealFallback : file)
                }
                .buttonStyle(.paper)
                Button("Add server…") { adding = true }.buttonStyle(.paperProminent)
            }
            .padding(.top, 20)
        }
    }

    private var revealFallback: String {
        switch place {
        case .you: ""
        case .project(let folder): folder.path
        }
    }

    private func load() async {
        guard let fresh = await model.mcpServers(at: place.destination) else { return }
        servers = fresh.servers
        problem = fresh.problem
        approvalsProblem = fresh.approvalsProblem
        if case .you = place, let snapshot = await model.sharedSnapshot() {
            file = snapshot.mcp.file
        } else if case .project(let folder) = place {
            file = folder.appending(path: ".agents/mcp.json").path
        }
    }
}

/// One of a project's servers. Waiting ones are already first. A missing secret is named,
/// never shown. Set…, Replace… and Remove… ask before they write (frame E).
private struct ProjectMCPRow: View {
    @Environment(AppModel.self) private var model
    let server: DaemonAPI.ProjectMCPServer
    let servers: [DaemonAPI.ProjectMCPServer]
    var place: AgentsPlace
    var file: String
    var changed: () -> Void = {}
    var failed: (String?) -> Void = { _ in }

    @State private var setting: [String] = []
    @State private var replacing = false
    @State private var removing = false
    @State private var signingIn = false

    private var setSecrets: [String] {
        server.secretNames.filter { !server.missingSecrets.contains($0) }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .appText(.reading)
                .foregroundStyle((isWaiting || !server.missingSecrets.isEmpty || needsSignIn ? StateTint.attention : StateTint.none).style(or: .secondary))
                .accessibilityLabel(isWaiting ? "Waiting for your OK" : "Server")
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(server.name).appText(.reading).fontWeight(.semibold).lineLimit(1)
                    if let managed = server.managed {
                        SharedChip(text: managed.byHand ? "added by hand" : "registry", tone: .source)
                    }
                    if isWaiting { SharedChip(text: "waiting for your OK", tone: .attention) }
                    ForEach(server.missingSecrets, id: \.self) { name in
                        SharedChip(text: "\(name) not set", tone: .attention)
                    }
                    if needsSignIn { SharedChip(text: "needs sign-in", tone: .attention) }
                    if server.signIn == .signedIn { SharedChip(text: "signed in", tone: .source) }
                }
                Text(detail).appText(.supporting).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                if let note {
                    Text(note).appText(.supporting).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                Button("Show entry") {
                    if !file.isEmpty { SharedFiles.open(file) }
                }
                .buttonStyle(.paper)
                .appText(.fine)
                if !server.missingSecrets.isEmpty {
                    Button("Set…") {
                        replacing = false
                        setting = server.missingSecrets
                    }
                    .buttonStyle(.paper)
                    .appText(.fine)
                }
                if !setSecrets.isEmpty {
                    Button("Replace…") {
                        replacing = true
                        setting = setSecrets
                    }
                    .buttonStyle(.paper)
                    .appText(.fine)
                }
                if needsSignIn {
                    Button("Sign in…") { signingIn = true }
                        .buttonStyle(.paper)
                        .appText(.fine)
                }
                if server.signIn == .signedIn {
                    Button("Sign out") {
                        Task {
                            failed(await model.mcpSignOut(signInTarget))
                            changed()
                        }
                    }
                    .buttonStyle(.paper)
                    .appText(.fine)
                }
                if case .project(let folder) = place, case .waiting(let digest, _) = server.approval {
                    Button("Approve") {
                        Task {
                            if let error = await model.approveProjectMCP(server.name, digest: digest, in: folder) {
                                failed(MCPCatalogWords.sentence(error))
                            } else {
                                failed(nil)
                                changed()
                            }
                        }
                    }
                    .buttonStyle(.paper)
                    .appText(.fine)
                }
                if server.managed != nil {
                    Button("Remove…") { removing = true }
                        .buttonStyle(.paper)
                        .appText(.fine)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .paperRow()
        .accessibilityElement(children: .contain)
        .sheet(isPresented: Binding(get: { !setting.isEmpty }, set: { if !$0 { setting = [] } })) {
            SetSecretSheet(serverName: server.name, names: setting, replacing: replacing, onSaved: changed)
        }
        .sheet(isPresented: $signingIn) {
            MCPSignInSheet(target: signInTarget, onSignedIn: changed)
        }
        .sheet(isPresented: $removing) {
            RemoveMCPServerSheet(server: server, destination: place.destination,
                                 forgettable: RemoveMCPServerSheet.forgettable(server, among: servers),
                                 keptSecret: RemoveMCPServerSheet.keptBecauseShared(server, among: servers),
                                 onRemoved: changed)
        }
    }

    private var needsSignIn: Bool { server.signIn == .needsSignIn }

    private var signInTarget: DaemonAPI.MCPSignInTarget {
        .entry(destination: place.destination, name: server.name)
    }

    private var isWaiting: Bool {
        if case .waiting = server.approval { true } else { false }
    }

    private var icon: String {
        if isWaiting { return "hand.raised" }
        if !server.missingSecrets.isEmpty || needsSignIn { return "exclamationmark.triangle" }
        return "point.3.connected.trianglepath.dotted"
    }

    private var detail: String {
        if let managed = server.managed, !managed.byHand, server.summary.contains("://") {
            return "\(server.summary) · \(managed.version)"
        }
        return server.summary
    }

    private var note: String? {
        if case .waiting(_, let isNew) = server.approval {
            return (isNew ? "New with the last pull. " : "Changed since you approved it. ")
                + "No agent is given it until you approve it."
        }
        if let name = server.missingSecrets.first {
            let extra = server.missingSecrets.count > 1 ? " (and \(server.missingSecrets.dropFirst().joined(separator: ", ")))" : ""
            return "Agents here start without it until you set \(name)\(extra)."
        }
        if needsSignIn {
            return "It asks you to sign in. Agents start without it until you do."
        }
        return nil
    }
}
