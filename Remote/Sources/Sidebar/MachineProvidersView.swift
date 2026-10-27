import AgentsKitCore
import SwiftUI

/// Settings ▸ Machine providers (#1819), as the web page's (#1808) and the window's
/// Settings ▸ Machine Providers: each provider as a section of its workspaces, Add
/// Provider… (kind first, then its short form), Edit…, List Again and Remove…, and on a
/// workspace Link to Host…, Start, Stop and Unlink. Only the API providers are added here;
/// the rest are the Mac's. Tokens go to the control plane and are not kept on the device.
struct MachineProvidersView: View {
    @Environment(RemoteModel.self) private var model
    @State private var adding = false
    @State private var editing: DaemonAPI.ProviderSummary?
    @State private var linking: Linking?
    @State private var removing: DaemonAPI.ProviderSummary?
    @State private var said: String?
    @State private var making: DaemonAPI.ProviderSummary?

    struct Linking: Identifiable {
        let provider: DaemonAPI.ProviderSummary
        let workspace: DaemonAPI.MachineInfo
        var id: String { "\(provider.id)/\(workspace.id)" }
    }

    private var oneCopy: Bool { model.machineProvidersProblem == MachineProviderWords.oneCopy }

    var body: some View {
        Form {
            if let problem = model.machineProvidersProblem {
                Section { Text(problem).foregroundStyle(oneCopy ? AnyShapeStyle(.secondary) : StateTint.failure.style(or: .secondary)) }
            }
            if let said {
                Section { Text(said).tinted(.failure) }
            }
            if !oneCopy {
                ForEach(model.machineProviders ?? []) { provider in
                    providerSection(provider)
                }
                Section {
                    // Only an admin adds one (#1761).
                    if model.isAdmin {
                        Button(MachineProviderWords.add) { adding = true }
                    }
                } footer: {
                    Text(MachineProviderWords.footer)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Paper.ground)
        .navigationTitle(MachineProviderWords.heading)
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if model.machineProviders == nil { ProgressView() }
        }
        // Lists every provider again when the page opens (FR-004).
        .task { await model.loadMachineProviders() }
        .refreshable { await model.loadMachineProviders() }
        .sheet(isPresented: $adding) { AddMachineProviderSheet(editing: nil) }
        .sheet(item: $editing) { AddMachineProviderSheet(editing: $0) }
        .sheet(item: $making) { provider in
            NavigationStack { NewMachinePage(picked: provider.id, close: { making = nil }) }
        }
        .sheet(item: $linking) { LinkWorkspaceToHostSheet(provider: $0.provider, workspace: $0.workspace) }
        .confirmationDialog(removing.map { MachineProviderWords.removeTitle($0.name) } ?? "",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible, presenting: removing) { provider in
            Button("Remove", role: .destructive) {
                Task { said = await model.removeWorkspaceProvider(provider.id) }
            }
        } message: { _ in
            Text(MachineProviderWords.removeNote)
        }
    }

    private func providerSection(_ provider: DaemonAPI.ProviderSummary) -> some View {
        Section {
            ForEach(provider.workspaces) { workspace in
                MachineProviderRow(provider: provider, workspace: workspace, say: { said = $0 }) {
                    linking = Linking(provider: provider, workspace: workspace)
                }
            }
        } header: {
            HStack {
                Text(provider.name)
                Spacer()
                Menu {
                    // The same New Machine as Add a Machine…, at this provider (#2131).
                    if provider.capabilities.contains("create"), provider.usable {
                        Button("New Machine…", systemImage: "plus") { making = provider }
                    }
                    Button("List Again", systemImage: "arrow.clockwise") {
                        Task { await model.listMachinesAgain(provider.id) }
                    }
                    // Who may start machines from it (#1761): an admin gives it to a group.
                    if model.isAdmin {
                        ProviderGroupPicker(provider: provider, groups: model.providerGroups) { group in
                            Task { said = await model.setProviderGroup(provider.id, group) }
                        }
                        .pickerStyle(.menu)
                        if APIProviderKind.ofPreset(provider.preset) != nil {
                            Button("Edit…", systemImage: "pencil") { editing = provider }
                        }
                        Button("Remove…", systemImage: "trash", role: .destructive) { removing = provider }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .accessibilityLabel("\(provider.name) actions")
                }
            }
        } footer: {
            let line = MachineProviderWords.providerLine(provider) { $0.formatted(date: .omitted, time: .shortened) }
            let group = GroupWords.providerLine(provider, groups: model.providerGroups) ?? ""
            Text([MachineProviderWords.kindChip(provider), line, group].filter { !$0.isEmpty }.joined(separator: " · "))
        }
        .paperListRow()
    }
}

/// A workspace of a provider: its state and host, and Start, Stop, Unlink or Link to Host….
private struct MachineProviderRow: View {
    @Environment(RemoteModel.self) private var model
    let provider: DaemonAPI.ProviderSummary
    let workspace: DaemonAPI.MachineInfo
    let say: (String?) -> Void
    let link: () -> Void
    @State private var stopAsk: String?
    @State private var unlinking = false

    var body: some View {
        let host = workspace.host.flatMap { id in model.controlHosts.first { $0.id == id } }
        let linked = host?.workspace
        let free = MachineProviderWords.linkableHosts(workspace, hosts: model.controlHosts)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                // The window's ControlDot: running, unknown, or anything else.
                Group {
                    switch workspace.state {
                    case "running": Circle().tinted(.vouched)
                    case "unknown": Circle().tinted(.attention)
                    default: Circle().foregroundStyle(.tertiary)
                    }
                }
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(workspace.name)
                    Text(linked?.phase ?? MachineProviderWords.workspaceLine(workspace, hosts: model.controlHosts))
                        .appText(.supporting)
                        .foregroundStyle(.secondary)
                    if let noHost = MachineProviderWords.noHostLine(workspace, hosts: model.controlHosts) {
                        Text(noHost)
                            .appText(.supporting)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            HStack(spacing: 8) {
                if let host, linked?.canStart == true {
                    let starting = model.hostsBeingStarted.contains(host.id)
                    Button(starting ? "Starting…" : "Start") { Task { await model.startHost(host.id) } }
                        .disabled(starting)
                }
                if let host, linked?.canStop == true {
                    Button("Stop") { Task { await stop(host.id, confirmed: false) } }
                }
                if host != nil {
                    Button("Unlink") { unlinking = true }
                }
                if workspace.host == nil, !free.isEmpty {
                    Button(free.count == 1 && MachineProviderWords.mayBe(workspace, hostName: free[0].name)
                           ? "Link to \(free[0].name)…" : "Link to Machine…", action: link)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .confirmationDialog(stopAsk ?? "", isPresented: Binding(get: { stopAsk != nil }, set: { if !$0 { stopAsk = nil } }),
                            titleVisibility: .visible) {
            Button("Stop Anyway", role: .destructive) {
                if let id = host?.id { Task { await stop(id, confirmed: true) } }
            }
        }
        .confirmationDialog(host.map { "Unlink \($0.name) from \(workspace.name)?" } ?? "", isPresented: $unlinking,
                            titleVisibility: .visible) {
            Button("Unlink", role: .destructive) {
                if let id = host?.id { Task { say(await model.unlinkWorkspace(host: id)) } }
            }
        } message: {
            Text("\(provider.name) can no longer start or stop it.")
        }
    }

    private func stop(_ host: MachineRef, confirmed: Bool) async {
        let answer = await model.stopMachine(host: host, confirmed: confirmed)
        if let ask = answer.ask { stopAsk = ask } else { say(answer.refused) }
    }
}

/// Add a Provider (kind first, then its form), or Edit… one: its name and its secrets again.
/// What is typed lives in this sheet only, and goes when it closes.
struct AddMachineProviderSheet: View {
    @Environment(RemoteModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let editing: DaemonAPI.ProviderSummary?
    @State private var kind: APIProviderKind?
    @State private var name = ""
    @State private var values: [String: String] = [:]
    @State private var problem: String?
    @State private var working = false

    var body: some View {
        NavigationStack {
            Form {
                if editing == nil {
                    Picker("Kind", selection: Binding(get: { kind }, set: { choose($0) })) {
                        Text("Choose…").tag(APIProviderKind?.none)
                        ForEach(APIProviderKind.allCases) { Text($0.title).tag(APIProviderKind?.some($0)) }
                    }
                }
                if let kind {
                    Section {
                        TextField("Name", text: $name, prompt: Text(kind.title))
                        ForEach(kind.fields.filter { editing == nil || $0.isSecret }) { field in
                            fieldRow(field)
                        }
                    } footer: {
                        Text(kind.needs)
                    }
                }
                if working {
                    Section { Text("Checking it lists its machines…").foregroundStyle(.secondary) }
                }
                if let problem {
                    Section { Text(problem).tinted(.failure) }
                }
                Section {} footer: { Text(MachineProviderWords.secretsFoot) }
            }
            .disabled(working)
            .navigationTitle(editing.map { "Edit \($0.name)" } ?? "Add a Provider")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(editing == nil ? "Add" : "Save") { Task { await save() } }
                        .disabled(kind == nil || working)
                }
            }
            .onAppear {
                if let editing {
                    kind = APIProviderKind.ofPreset(editing.preset)
                    name = editing.name
                }
            }
        }
    }

    @ViewBuilder
    private func fieldRow(_ field: APIProviderKind.Field) -> some View {
        let binding = Binding(get: { values[field.id] ?? "" }, set: { values[field.id] = $0 })
        let label = field.label + (field.isOptional ? " (optional)" : "")
        let prompt = editing != nil && field.isSecret ? MachineProviderWords.editSecret : field.prompt
        if field.isLong {
            VStack(alignment: .leading) {
                Text(label).appText(.supporting).foregroundStyle(.secondary)
                TextEditor(text: binding)
                    .frame(minHeight: 90)
                    .appText(.code)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if let prompt { Text(prompt).appText(.supporting).foregroundStyle(.tertiary) }
            }
        } else if field.isSecret {
            SecureField(label, text: binding, prompt: prompt.map { Text($0) })
                .textContentType(.password)
        } else {
            TextField(label, text: binding, prompt: prompt.map { Text($0) })
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
    }

    private func choose(_ new: APIProviderKind?) {
        kind = new
        values = Dictionary(uniqueKeysWithValues: (new?.fields ?? []).compactMap { f in f.value.map { (f.id, $0) } })
        problem = nil
    }

    private func save() async {
        guard let kind else { return }
        switch kind.request(name: name, values: values, editing: editing) {
        case .failure(let missing):
            problem = missing.sentence
        case .success(let request):
            working = true
            problem = nil
            let refused = await model.saveWorkspaceProvider(request)
            working = false
            if let refused { problem = refused } else { dismiss() }
        }
    }
}

/// Link to Host (#691 L5): a host that already runs on this workspace, with when to start
/// and stop it.
private struct LinkWorkspaceToHostSheet: View {
    @Environment(RemoteModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let provider: DaemonAPI.ProviderSummary
    let workspace: DaemonAPI.MachineInfo
    @State private var host: MachineRef?
    @State private var startWhenUsed = true
    @State private var idle = WorkspaceLink.defaultIdleMinutes
    @State private var problem: String?

    var body: some View {
        let hosts = MachineProviderWords.linkableHosts(workspace, hosts: model.controlHosts)
        NavigationStack {
            Form {
                Section {
                    if hosts.isEmpty {
                        Text(MachineProviderWords.noHosts)
                    } else {
                        Picker("Machine", selection: $host) {
                            ForEach(hosts) { Text($0.name).tag(MachineRef?.some($0.id)) }
                        }
                        Toggle("Start when used", isOn: $startWhenUsed)
                        Picker("Stop when idle", selection: $idle) {
                            ForEach(MachineProviderWords.idleChoices, id: \.minutes) { Text($0.label).tag($0.minutes) }
                        }
                    }
                } footer: {
                    Text("Agents already runs on this machine: \(provider.name) starts and stops it, and nothing is installed again.")
                }
                if let problem {
                    Section { Text(problem).tinted(.failure) }
                }
            }
            .navigationTitle("Link \(workspace.name) to a Machine")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Link") {
                        guard let host else { return }
                        Task {
                            problem = await model.linkWorkspace(host: host, provider: provider.id, workspace: workspace.id,
                                                                startWhenUsed: startWhenUsed, stopWhenIdleMinutes: idle)
                            if problem == nil { dismiss() }
                        }
                    }
                    .disabled(host == nil)
                }
            }
            .onAppear { host = host ?? hosts.first?.id }
        }
    }
}
