import AgentsKitCore
import SwiftUI

/// Settings ▸ Control plane ▸ Providers (#691, layouts.md L3): each workspace provider as a
/// card of its workspaces, which are hosts already or can be added as one. A provider runs on
/// the control plane, so it can start a host that is down.
struct ControlProvidersPage: View {
    let control: ControlSettingsModel
    @State private var adding = false
    @State private var removing: DaemonAPI.ProviderSummary?
    @State private var addingHost: ControlAddServerSheet.Prefill?
    /// New Workspace… (US5, L9).
    @State private var making: DaemonAPI.ProviderSummary?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !control.providersHere {
                Text("Workspace providers need a control plane with one copy, such as the one on your Mac. This one has several.")
                    .appText(.supporting).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(control.providers) { provider in
                    providerCard(provider)
                }
                Button("Add Provider…") { adding = true }.buttonStyle(.paper)
                Text("A provider starts and stops the machines your hosts run on: Docker containers, DigitalOcean droplets, Codespaces, or anything with a command. It runs here, on the control plane, so it can start a host that is down.")
                    .appText(.supporting).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        // Lists every provider again when the page opens (FR-004).
        .task { await control.listWorkspacesAgain() }
        .sheet(isPresented: $adding) { AddProviderSheet(control: control).paperSheet() }
        .sheet(item: $addingHost) { prefill in ControlAddServerSheet(control: control, prefill: prefill).paperSheet() }
        .sheet(item: $making) { provider in
            NewWorkspaceSheet(control: control, provider: provider) { prefill in
                // After this sheet has gone, so the next can come up.
                Task { @MainActor in addingHost = prefill }
            }
            .paperSheet()
        }
        .confirmationDialog(removing.map { "Remove \($0.name)?" } ?? "",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible, presenting: removing) { provider in
            Button("Remove", role: .destructive) { Task { await control.removeProvider(provider.id) } }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Its hosts stay, unlinked: nothing here can start or stop them any more. Its workspaces are left as they are.")
        }
    }

    private func providerCard(_ provider: DaemonAPI.ProviderSummary) -> some View {
        ControlCard {
            ControlRow(dot: .none, title: provider.name, chip: kindChip(provider), detail: providerLine(provider)) {
                HStack(spacing: 8) {
                if provider.capabilities.contains("create") {
                    Button("New Workspace…") { making = provider }.buttonStyle(.paper)
                }
                Menu {
                    Button("List Again") { Task { await control.listWorkspacesAgain(provider.id) } }
                    Divider()
                    Button("Remove…") { removing = provider }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("More for \(provider.name)")
                }
                .fixedSize()
            }
            ForEach(provider.workspaces) { workspace in
                Divider()
                ControlRow(dot: dot(workspace), title: workspace.name, detail: workspaceLine(workspace, of: provider)) {
                    if control.isJoining(provider.id, workspace) {
                        // Made here, installing on its first boot (US5).
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Joining…").appText(.supporting).foregroundStyle(.secondary)
                        }
                    } else if workspace.host == nil {
                        Button("Add as Host…") {
                            addingHost = .init(destination: workspace.ssh ?? "", name: workspace.name,
                                               tunnel: workspace.tunnel ?? false, provider: provider.id,
                                               workspace: workspace.id)
                        }
                        .buttonStyle(.paper)
                        .disabled(workspace.ssh == nil || workspace.state != "running")
                        .help(workspace.ssh == nil ? "\(provider.name) gives no ssh destination for it: add it by command, then Link to Workspace… on its host."
                              : workspace.state == "running" ? "Installs Agents on it over ssh, and links the host to it."
                              : "Start it first: it has to be running to be installed.")
                    }
                }
            }
        }
    }

    private func kindChip(_ provider: DaemonAPI.ProviderSummary) -> String {
        if let preset = provider.preset { return "command provider · \(preset)" }
        switch provider.kind {
        case "commands": return "command provider"
        case "http": return provider.mapped ? "address · mapped" : "address"
        default: return provider.mapped ? "command · mapped" : "command"
        }
    }

    private func providerLine(_ provider: DaemonAPI.ProviderSummary) -> String {
        var parts: [String] = []
        if let problem = provider.problem, !provider.current || provider.listedAt == nil {
            parts.append("Couldn’t list: \(problem)")
        }
        if let at = provider.listedAt {
            parts.append("\(provider.current ? "Listed" : "Showing what it listed at") \(at.formatted(date: .omitted, time: .shortened))")
        }
        if provider.workspaces.isEmpty, provider.listedAt != nil { parts.append("No workspaces") }
        return parts.joined(separator: " · ")
    }

    private func dot(_ workspace: DaemonAPI.WorkspaceInfo) -> ControlDot {
        switch workspace.state {
        case "running": .online
        case "unknown": .attention
        default: .offline
        }
    }

    private func workspaceLine(_ workspace: DaemonAPI.WorkspaceInfo, of provider: DaemonAPI.ProviderSummary) -> String {
        var parts = [workspace.state.capitalized]
        if let host = workspace.host {
            parts.append("linked to \(control.hosts.first { $0.id == host }?.name ?? "a host")")
        } else {
            parts.append("not a host")
        }
        if let cost = workspace.cost { parts.append(cost) }
        return parts.joined(separator: " · ")
    }
}

/// Add a Provider (#691, layouts.md L4, as Alex chose it): pick what kind first, then a short
/// form for just that kind. A preset needs its CLI signed in where the control plane runs.
struct AddProviderSheet: View {
    @Environment(\.dismiss) private var dismiss
    let control: ControlSettingsModel

    enum Kind: String, CaseIterable, Identifiable {
        case docker, digitalOcean, codespaces, coder, workstations, commands, mcp
        var id: String { rawValue }

        var title: String {
            switch self {
            case .docker: "Docker"
            case .digitalOcean: "DigitalOcean"
            case .codespaces: "Codespaces"
            case .coder: "Coder"
            case .workstations: "Workstations"
            case .commands: "Your commands"
            case .mcp: "MCP server"
            }
        }

        var symbol: String {
            switch self {
            case .docker: "shippingbox"
            case .digitalOcean: "drop"
            case .codespaces: "chevron.left.forwardslash.chevron.right"
            case .coder: "terminal"
            case .workstations: "cloud"
            case .commands: "apple.terminal"
            case .mcp: "point.3.connected.trianglepath.dotted"
            }
        }

        /// What it needs where the control plane runs.
        var needs: String? {
            switch self {
            case .docker: "Needs docker on the Mac that runs the control plane."
            case .digitalOcean: "Needs doctl, signed in, on the Mac that runs the control plane."
            case .codespaces: "Needs gh, signed in, on the Mac that runs the control plane."
            case .coder: "Needs coder, signed in, and `coder config-ssh` run, on the Mac that runs the control plane."
            case .workstations: "Needs gcloud, signed in, on the Mac that runs the control plane."
            case .commands: "The commands run on the Mac that runs the control plane, as you."
            case .mcp: "An MCP server that offers workspaces_list, workspace_start and workspace_stop, or a tool map onto its own tools."
            }
        }
    }

    @State private var kind: Kind?
    @State private var name = ""
    // Presets
    @State private var containers = ""
    @State private var ssh = ""
    @State private var tag = "agents"
    @State private var user = "root"
    @State private var repo = ""
    @State private var cluster = ""
    @State private var config = ""
    @State private var region = ""
    // Your commands
    @State private var workspace = ""
    @State private var start = ""
    @State private var stop = ""
    @State private var status = ""
    // MCP server
    @State private var byAddress = false
    @State private var command = ""
    @State private var url = ""
    @State private var map = ""
    // Secrets: entered once, never shown again.
    @State private var secrets: [Secret] = []
    @State private var working = false
    @State private var problem: String?

    struct Secret: Identifiable {
        let id = UUID()
        var name = ""
        var value = ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(kind.map { "Add \($0.title)" } ?? "Add a Provider").appText(.title).fontWeight(.semibold)
            if let kind {
                form(kind)
            } else {
                grid
            }
        }
        .padding(28)
        .frame(width: 560)
    }

    // MARK: Pick a kind

    private var grid: some View {
        VStack(alignment: .leading, spacing: 14) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 116), spacing: 10)], spacing: 10) {
                ForEach(Kind.allCases) { each in
                    Button { choose(each) } label: {
                        VStack(spacing: 8) {
                            // Decorative: the kind's name is under it.
                            Image(systemName: each.symbol).imageScale(.large).accessibilityHidden(true)
                            Text(each.title).appText(.supporting)
                        }
                        .frame(maxWidth: .infinity, minHeight: 64)
                    }
                    .buttonStyle(.paper)
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
    }

    private func choose(_ each: Kind) {
        kind = each
        problem = nil
        name = switch each {
        case .docker: "Docker on this Mac"
        case .commands, .mcp: ""
        default: each.title
        }
    }

    // MARK: Its form

    @ViewBuilder
    private func form(_ kind: Kind) -> some View {
        Form {
            TextField("Name", text: $name)
            switch kind {
            case .docker:
                TextField("Containers", text: $containers, prompt: Text("agents-devbox, other"))
                TextField("ssh", text: $ssh, prompt: Text("alex@127.0.0.1 -p 2222"))
            case .digitalOcean:
                TextField("Droplets tagged", text: $tag)
                TextField("ssh as", text: $user)
            case .codespaces:
                TextField("Repository", text: $repo, prompt: Text("Every codespace, or owner/repo"))
            case .coder:
                EmptyView()
            case .workstations:
                TextField("Cluster", text: $cluster)
                TextField("Configuration", text: $config)
                TextField("Region", text: $region)
            case .commands:
                TextField("Workspace", text: $workspace, prompt: Text("devstack"))
                TextField("ssh", text: $ssh, prompt: Text("devstack-1.cws"))
                TextField("Start", text: $start, prompt: Text("cws start devstack-1"))
                TextField("Stop", text: $stop, prompt: Text("cws stop devstack-1"))
                TextField("Status", text: $status, prompt: Text("Optional: prints running or stopped"))
            case .mcp:
                Picker("Server", selection: $byAddress) {
                    Text("A command").tag(false)
                    Text("An address").tag(true)
                }
                .pickerStyle(.segmented)
                if byAddress {
                    TextField("Address", text: $url, prompt: Text("https://…/mcp"))
                } else {
                    TextField("Command", text: $command, prompt: Text("npx -y @digitalocean/mcp"))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Tool map").appText(.supporting)
                    TextEditor(text: $map)
                        .appText(.code)
                        .frame(height: 90)
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Paper.rule))
                        .accessibilityLabel("Tool map")
                    Text("Leave it empty for a server that follows the contract.").appText(.fine).foregroundStyle(.secondary)
                }
            }
            secretsSection
        }
        .formStyle(.grouped)
        if let needs = kind.needs {
            Text(needs).appText(.supporting).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        if let problem {
            Text(problem).appText(.supporting).tinted(.failure).fixedSize(horizontal: false, vertical: true)
        }
        HStack {
            Button("Back") { self.kind = nil; problem = nil }
            Spacer()
            if working { ProgressView().controlSize(.small) }
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            Button("Add") { add(kind) }
                .keyboardShortcut(.defaultAction)
                .disabled(working || name.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    @ViewBuilder
    private var secretsSection: some View {
        Section {
            ForEach($secrets) { $secret in
                HStack {
                    TextField("Name", text: $secret.name, prompt: Text("TOKEN")).frame(maxWidth: 180)
                    SecureField("Value", text: $secret.value)
                    Button {
                        secrets.removeAll { $0.id == secret.id }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Remove \(secret.name.isEmpty ? "this secret" : secret.name)")
                }
            }
            Button("Add Secret") { secrets.append(Secret()) }
        } header: {
            Text("Secrets")
        } footer: {
            Text("Given to the provider as environment, or as ${NAME} in its headers. Kept on the control plane, never shown again.")
                .appText(.fine).foregroundStyle(.secondary)
        }
    }

    private func add(_ kind: Kind) {
        let request: DaemonAPI.ProviderAdd
        do {
            request = try self.request(kind)
        } catch {
            problem = "\(error)"
            return
        }
        working = true
        problem = nil
        Task {
            let refused = await control.addProvider(request)
            working = false
            if let refused { problem = refused } else { dismiss() }
        }
    }

    struct Wrong: Error, CustomStringConvertible { var description: String }

    private func request(_ kind: Kind) throws -> DaemonAPI.ProviderAdd {
        func trimmed(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
        let given = Dictionary(secrets.filter { !trimmed($0.name).isEmpty }.map { (trimmed($0.name), $0.value) }) { $1 }
        let name = trimmed(self.name)
        var commands: [String: JSONValue] = [:]
        switch kind {
        case .docker:
            let names = containers.split(separator: ",").map { trimmed(String($0)) }.filter { !$0.isEmpty }
            guard !names.isEmpty else { throw Wrong(description: "Name at least one container.") }
            commands = ["preset": "docker", "containers": .array(names.map(JSONValue.string))]
            if !trimmed(ssh).isEmpty { commands["ssh"] = .string(trimmed(ssh)) }
        case .digitalOcean:
            commands = ["preset": "doctl", "tag": .string(trimmed(tag)), "user": .string(trimmed(user).isEmpty ? "root" : trimmed(user))]
        case .codespaces:
            commands = ["preset": "codespaces"]
            if !trimmed(repo).isEmpty { commands["repo"] = .string(trimmed(repo)) }
        case .coder:
            commands = ["preset": "coder"]
        case .workstations:
            commands = ["preset": "gcloud-workstations", "cluster": .string(trimmed(cluster)),
                        "config": .string(trimmed(config)), "region": .string(trimmed(region))]
        case .commands:
            guard !trimmed(workspace).isEmpty, !trimmed(start).isEmpty, !trimmed(stop).isEmpty else {
                throw Wrong(description: "Give the workspace a name, and its Start and Stop commands.")
            }
            var entry: [String: JSONValue] = ["name": .string(trimmed(workspace)), "start": .string(trimmed(start)),
                                              "stop": .string(trimmed(stop))]
            if !trimmed(status).isEmpty { entry["status"] = .string(trimmed(status)) }
            if !trimmed(ssh).isEmpty { entry["ssh"] = .string(trimmed(ssh)) }
            commands = ["workspaces": [.object(entry)]]
        case .mcp:
            var mapped: JSONValue?
            if !trimmed(map).isEmpty {
                guard let parsed = try? JSONValue.parse(Data(map.utf8)) else { throw Wrong(description: "The tool map isn’t JSON.") }
                mapped = parsed
            }
            if byAddress {
                // An address's one secret is its bearer token.
                let token = given.keys.sorted().first
                return DaemonAPI.ProviderAdd(name: name, kind: .http, url: trimmed(url),
                                             headers: token.map { ["Authorization": "Bearer ${\($0)}"] },
                                             map: mapped, secrets: given)
            }
            let words = trimmed(command).split(separator: " ").map(String.init)
            guard let first = words.first else { throw Wrong(description: "Give the command that runs the server.") }
            return DaemonAPI.ProviderAdd(name: name, kind: .stdio, command: first, args: Array(words.dropFirst()),
                                         map: mapped, secrets: given)
        }
        return DaemonAPI.ProviderAdd(name: name, kind: .commands, commands: .object(commands), secrets: given)
    }
}

/// Link to Workspace… (#691, layouts.md L5): a provider's workspace for a host that is already
/// one. A workspace another host has is shown, greyed, as that host's.
struct LinkWorkspaceSheet: View {
    @Environment(\.dismiss) private var dismiss
    let control: ControlSettingsModel
    let host: DaemonAPI.ControlHost

    @State private var chosen: String?
    @State private var startWhenUsed = true
    @State private var stopWhenIdle = WorkspaceLink.defaultIdleMinutes

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Link \(host.name) to a Workspace").appText(.title).fontWeight(.semibold)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(control.providers) { provider in
                        Text(provider.name).appText(.reading).fontWeight(.semibold)
                        ForEach(provider.workspaces) { workspace in
                            row(provider, workspace)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 280)
            Toggle("Start when used", isOn: $startWhenUsed)
            Picker("Stop when idle", selection: $stopWhenIdle) {
                Text("Off").tag(0)
                Text("After 15 minutes").tag(15)
                Text("After 30 minutes").tag(30)
                Text("After 1 hour").tag(60)
                Text("After 2 hours").tag(120)
            }
            .fixedSize()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Link") { link() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(chosen == nil)
            }
        }
        .padding(28)
        .frame(width: 460)
    }

    private func key(_ provider: DaemonAPI.ProviderSummary, _ workspace: DaemonAPI.WorkspaceInfo) -> String {
        "\(provider.id.rawValue)/\(workspace.id)"
    }

    private func row(_ provider: DaemonAPI.ProviderSummary, _ workspace: DaemonAPI.WorkspaceInfo) -> some View {
        let other = workspace.host.flatMap { id in control.hosts.first { $0.id == id }?.name }
        let selected = chosen == key(provider, workspace)
        return Button {
            chosen = key(provider, workspace)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle").accessibilityHidden(true)
                Text(workspace.name).appText(.reading)
                Text(other.map { "linked to \($0)" } ?? workspace.state.capitalized)
                    .appText(.supporting).foregroundStyle(.secondary)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(other != nil)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .padding(.leading, 12)
    }

    private func link() {
        guard let chosen, let slash = chosen.firstIndex(of: "/") else { return }
        let provider = ProviderID(rawValue: String(chosen[..<slash]))
        let workspace = String(chosen[chosen.index(after: slash)...])
        Task {
            await control.link(host.id, to: provider, workspace: workspace,
                               startWhenUsed: startWhenUsed, stopWhenIdleMinutes: stopWhenIdle)
            dismiss()
        }
    }
}
