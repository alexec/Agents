import AgentsKitCore
import SwiftUI

/// One machine's page in the main window (#3626): the place to go for its status. A summary
/// first (#3743): its CPU, load and capacity (#4582), memory and worst disk on one line. Then the detail, most of it
/// closed until the person opens it: the disk that matters with the others folded, a row
/// per folder's worktrees (#3627), the runtimes installed there (#3629), resources only
/// when one is declared or held, and its processes (#3453). Read with
/// `machine/usage` when it opens and every few seconds while it is open, never otherwise.
/// A machine a provider made has its provider's options and Unlink here, and one that uses a Mac's
/// git access has Stop Lending (#3975: Settings ▸ Machines lists no machines now). This Mac's own
/// settings stay in Settings ▸ Machines; Settings… goes there. The web page draws the same in Web/src/views/MachinePage.tsx.
struct MachinePage: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    let host: MachineRef

    @State private var usage: DaemonAPI.MachineUsageState?
    @State private var failure: String?

    private var name: String { model.hosts.label(host) }
    private var offline: Bool { model.hosts.isOffline(host) }
    private var answersUsage: Bool { model.host(host, has: Capability.machineUsage1) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(name).appText(.reading)
                    Text(offline ? "Offline" : "Online")
                        .appText(.supporting)
                        .foregroundStyle(offline ? StateTint.failure.style(or: .secondary) : AnyShapeStyle(.secondary))
                }
                Spacer(minLength: 0)
                if host == .mac {
                    Button("Settings…") {
                        model.settingsPaneAsked = .machines
                        openSettings()
                    }
                    .help("\(name)’s sleep, backups and desktop control, in Settings ▸ Machines")
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)

            ScrollViewReader { proxy in
                Form {
                    if offline {
                        Section {
                            Text("\(name) is offline, so it can’t say how it is doing now.")
                                .foregroundStyle(.secondary)
                        }
                    } else if !answersUsage {
                        Section {
                            Text("Update Agents on \(name) to see its CPU, memory and disks here.")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        summarySection
                        disksSection
                    }
                    if let row = model.hosts.controlRows[host] {
                        MachineLinkSections(row: row)
                    }
                    if !offline {
                        MachineWorktreesSections(host: host)
                        MachineRuntimesSection(host: host)
                        MachineResourcesSection(host: host)
                    }
                    if !offline, model.host(host, has: Capability.processes1) {
                        MachineProcessesSection(client: model.client(for: host), hostName: name, showsTotals: false, folds: true)
                    }
                }
                .paperForm()
                .onAppear { scroll(proxy) }
                .onChange(of: model.resourcesAsked) { scroll(proxy) }
                .onChange(of: model.leases(on: host)?.resources.count) { scroll(proxy) }
            }
        }
        .navigationTitle(name)
        .task(id: offline ? nil : host) {
            guard !offline else { return }
            await MachineResourcesSection.read(model, on: host)
        }
        .task(id: host) {
            usage = nil
            failure = nil
            guard answersUsage else { return }
            while !Task.isCancelled {
                if !offline { await read() }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    /// The disk the summary names and the Disks section shows open (#3743).
    private var headline: DiskAlarm? {
        guard let usage else { return nil }
        let folders = model.work.worktreesForCleanup(on: host).map { $0.folder.path(percentEncoded: false) }
        return DiskSpace.headline(usage.disks, folders: folders)
    }

    /// The sessions here that wait for a place to start (#4377), for the summary's second line (#4582).
    private var queuedStarts: Int {
        model.work.agents.filter { $0.host == host && $0.state == .queued }.count
    }

    /// "Is this machine OK?" in one line (#3743): CPU, the load and the level (#4582), memory and
    /// the worst disk, each in its tint. Above it at near and full, why, in the level's tint; under
    /// it, the starts that wait.
    @ViewBuilder
    private var summarySection: some View {
        Section {
            if let usage {
                if let warning = CapacityWords.warning(usage.machine, name: name) {
                    Text(warning)
                        .foregroundStyle(Self.tint(usage.machine.capacity).style(or: .primary))
                        .monospacedDigit()
                }
                HStack(spacing: 0) {
                    Text("CPU \(ProcessWords.cpu(usage.machine.cpuPercent))")
                    if let load = usage.machine.loadPerCore {
                        Text(" · \(CapacityWords.load(load))")
                            .help(CapacityWords.detail(usage.machine) ?? "")
                    }
                    if let level = CapacityWords.level(usage.machine.capacity) {
                        Text(" · ")
                        Text(level).foregroundStyle(Self.tint(usage.machine.capacity).style(or: .primary))
                    }
                    Text(" · Memory \(ProcessWords.machineMemory(usage.machine))")
                    if let disk = headline {
                        Text(" · ")
                        Text(DiskSpace.summaryWords(disk))
                            .foregroundStyle(Self.tint(disk.level).style(or: .primary))
                            .help(disk.level == .ok ? disk.reading.volume : disk.line)
                    }
                }
                .monospacedDigit()
                .help(ProcessWords.machineCPU(usage.machine))
                // The starts that wait, and the leases that wait for the machine (#4748).
                let waits = [CapacityWords.queued(queuedStarts),
                             CapacityWords.leasesInLine(CapacityWords.leasesInLine(model.leases(on: host)?.resources ?? []))]
                    .compactMap { $0 }
                if !waits.isEmpty {
                    Text(waits.joined(separator: " · ")).foregroundStyle(.secondary)
                }
            } else if let failure {
                Text(failure).foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
        }
    }

    /// The disk that is low, or the folders' own when all are OK, with the others closed under
    /// Other disks (#3743).
    @ViewBuilder
    private var disksSection: some View {
        if let usage {
            Section {
                if usage.disks.isEmpty {
                    Text("No disk looked at yet. \(name) looks every minute.").foregroundStyle(.secondary)
                }
                let shown = usage.disks.filter { $0.level != .ok || $0.id == headline?.id }
                ForEach(shown) { disk in diskRow(disk) }
                let others = usage.disks.filter { disk in !shown.contains { $0.id == disk.id } }
                if !others.isEmpty {
                    DisclosureGroup("Other disks (\(others.count))") {
                        ForEach(others) { disk in diskRow(disk) }
                    }
                }
            } header: {
                Text("Disks")
                    .help("Each disk its agents write to. Low and almost full are the lines set in Folder Settings ▸ Disk Space.")
            }
        }
    }

    private func diskRow(_ disk: DiskAlarm) -> some View {
        LabeledContent {
            HStack(spacing: 8) {
                Text(DiskSpace.freeWords(disk.reading)).monospacedDigit().fixedSize()
                Text(DiskSpace.levelWords(disk.level))
                    .foregroundStyle(Self.tint(disk.level).style(or: .secondary))
            }
        } label: {
            Text(disk.reading.volume)
        }
        .help(disk.level == .ok ? disk.reading.mount : "\(disk.reading.mount): \(disk.line)")
    }

    static func tint(_ level: DaemonAPI.CapacityLevel?) -> StateTint {
        switch level {
        case .ok, nil: .none
        case .near: .attention
        case .full: .failure
        }
    }

    static func tint(_ level: DiskLevel) -> StateTint {
        switch level {
        case .ok: .none
        case .low: .attention
        case .critical: .failure
        }
    }

    /// To the resource a chat's capsule named, or the Resources section, once (#3629). Only
    /// This Mac's page is asked; the leases may arrive after the page does.
    private func scroll(_ proxy: ScrollViewProxy) {
        guard host == .mac, let asked = model.resourcesAsked, model.leases != nil else { return }
        withAnimation(ResponseMotion.response) {
            if let name = asked.name, model.leases?.resources.contains(where: { $0.name == name }) == true {
                proxy.scrollTo(name, anchor: .top)
            } else {
                proxy.scrollTo(MachineResourcesSection.top, anchor: .top)
            }
        }
        model.resourcesAsked = nil
    }

    private func read() async {
        do {
            usage = try await model.client(for: host).call(DaemonAPI.Method.machineUsage, DaemonAPI.Empty(),
                                                             returning: DaemonAPI.MachineUsageState.self)
            failure = nil
        } catch let error as JSONRPCError {
            failure = error.message
        } catch {
            failure = "\(name) can’t be asked now: \(error.localizedDescription)"
        }
    }
}

/// What Settings ▸ Machines' menu had for one machine and its row's menu leaves out (#3975):
/// a provider's options and Unlink (rare, so not in the row's menu; the wireframe's section 4),
/// and Stop Lending for each git server it uses a Mac's access for (#1122).
private struct MachineLinkSections: View {
    @Environment(AppModel.self) private var model
    let row: DaemonAPI.ControlMachine
    @State private var unlinking = false

    var body: some View {
        if let workspace = row.workspace {
            Section {
                Toggle("Start when used", isOn: Binding(
                    get: { workspace.startWhenUsed },
                    set: { on in Task { await model.setMachineOptions(row.id, startWhenUsed: on) } }))
                Toggle("Start for scheduled workflows", isOn: Binding(
                    get: { workspace.startForSchedules ?? true },
                    set: { on in Task { await model.setMachineOptions(row.id, startForSchedules: on) } }))
                Picker("Stop when idle", selection: Binding(
                    get: { workspace.stopWhenIdleMinutes ?? 0 },
                    set: { minutes in Task { await model.setMachineOptions(row.id, stopWhenIdleMinutes: minutes) } })) {
                    ForEach(MachineProviderWords.idleChoices, id: \.minutes) { Text($0.label).tag($0.minutes) }
                }
                Button("Unlink from \(workspace.workspaceName)…") { unlinking = true }
            } header: {
                Text("\(workspace.providerName): \(workspace.workspaceName)")
            } footer: {
                if let words = footer(workspace) { Text(words) }
            }
            .confirmationDialog("Unlink \(row.name) from \(workspace.workspaceName)?", isPresented: $unlinking,
                                titleVisibility: .visible) {
                Button("Unlink") { Task { await model.unlinkMachine(row.id) } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("\(workspace.providerName) can no longer start or stop it.")
            }
        }
        if let lent = row.gitFrom, !lent.isEmpty {
            Section {
                ForEach(lent.keys.sorted(), id: \.self) { server in
                    Button(GitLendWords.revoke(server)) {
                        Task { await model.stopLendingGit(row.id, from: lent[server]!, server: server) }
                    }
                }
            } header: {
                Text("Git access")
            } footer: {
                if let uses = GitLendWords.uses(row, name: { model.hosts.label($0) }) { Text(uses) }
            }
        }
    }

    /// When it starts again or stays up (#1004 FR-007), and the scheduled workflows it does
    /// not run while stopped (L8), as its row in Settings ▸ Machines said.
    private func footer(_ workspace: DaemonAPI.MachineWorkspace) -> String? {
        var lines: [String] = []
        if let problem = workspace.problem { lines.append(problem) }
        if row.state != "online", let wake = OfflineWords.wakeLine(workspace) { lines.append(wake) }
        if row.state == "online", let up = OfflineWords.staysUpLine(workspace) { lines.append(up) }
        let started = (workspace.startForSchedules ?? true) && workspace.tellsSchedule == true
        let scheduled = workspace.stopWhenIdleMinutes == nil || started ? 0 : model.work.folders.filter { $0.host == row.id }
            .flatMap { model.work.workflows(in: $0.folder.folder) }
            .filter { !$0.isArchived && $0.isEnabled && !$0.workflow.schedules.isEmpty }
            .count
        if scheduled > 0 {
            lines.append("\(scheduled == 1 ? "1 scheduled workflow here doesn’t" : "\(scheduled) scheduled workflows here don’t") run while it is stopped.")
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}

/// A machine's row under Machines in the sidebar (#3626): its name and its dot, and under it,
/// in grey, the most urgent thing it needs (#3764). The dot and the line say only the machine's
/// own state: its sessions do not roll up into it (#3973). Its menu and swipes start, stop,
/// delete or remove it, as the web page's rows do (#3974).
struct MachineRow: View {
    @Environment(AppModel.self) private var model
    let host: MachineRef
    let open: () -> Void
    @State private var deleting = false
    /// What Delete loses: the worktrees on it with work not pushed (#3979), asked as it opens.
    @State private var deleteWork: DaemonAPI.StartedMachinePreview?
    @State private var askingWork = false
    @State private var removing = false
    /// Stop, asked first while agents work there, with who they are.
    @State private var stoppingNames: [String] = []
    /// A sheet from its menu (#3979), as Settings ▸ Machines opened them.
    @State private var sheet: MachineSheet?
    /// The control plane's model, for the sheets that need it, made as one opens.
    @State private var control: ControlSettingsModel?

    var body: some View {
        let name = model.hosts.label(host)
        let row = model.hosts.controlRows[host]
        let need = model.need(of: host)
        let words = need.map { MachineNeedWords.line($0, name: name, row: row) }
        let actions = MachineRowActions.of(row, isThisMac: host == .mac)
        let dot = MachineDot.of(row, online: !model.hostUnreachable(host),
                                starting: model.hostsBeingStarted.contains(host))
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            // A laptop, a cloud or a rack, in its state's colour (#4113): the row has no dot.
            MachineIconView(symbol: MachineIcon.symbol(isThisMac: host == .mac, row: row),
                            icon: MachineIcon.of(dot, diskLow: model.diskWarns(host), capacity: model.capacityLevel(host)))
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).foregroundStyle(.primary).lineLimit(1)
                if let words {
                    Text(words)
                        .appText(.fine)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 4)
        }
        .help(words.map { "\(name): \($0)" } ?? (model.diskWarns(host)
            ? "\(name): a disk is low. Its CPU, memory, disks, worktrees, runtimes and resources"
            : "\(name): its CPU, memory, disks, worktrees, runtimes and resources"))
        .accessibilityElement(children: .contain)
        .accessibilityValue(words ?? (dot == .online ? "Online" : ""))
        .swipeActions(edge: .leading) {
            if actions.start {
                SwipeAction("Start", systemImage: "play") { await model.startHost(host) }.tint(Paper.accent)
            } else if actions.stop {
                SwipeAction("Stop", systemImage: "stop") { await stop() }.tint(Paper.accent)
            }
        }
        // A full swipe never deletes: Delete and Remove ask first.
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if actions.delete {
                Button("Delete", systemImage: "trash", role: .destructive) { askDelete() }
            } else if actions.remove {
                Button("Remove", systemImage: "minus.circle") { removing = true }.tint(.gray)
            }
        }
        .contextMenu {
            Button("Open", action: open)
            // This Mac's one item, as its row in Settings ▸ Machines had it (#656, #3975).
            if let row, host == .mac {
                Divider()
                Button("Choose Folders…") { show(.folders) }.disabled(!row.answers)
            }
            if let row, host != .mac {
                // The items of Settings ▸ Machines' menu, moved here (#3979).
                Divider()
                if actions.start {
                    Button("Start") { Task { await model.startHost(host) } }
                } else if actions.stop {
                    Button("Stop") { Task { await stop() } }
                }
                Button("Check Again") { Task { await model.checkAgain(host) } }
                if row.state == "needsUpdate" {
                    Button("Update…") { show(.update) }
                }
                Divider()
                Button("Choose Folders…") { show(.folders) }.disabled(!row.answers)
                if model.host(host, has: Capability.backups1) {
                    Button("Backups…") { show(.backups) }.disabled(!row.answers)
                }
                if model.host(host, has: Capability.processes1) {
                    Button("Processes…") { show(.processes) }.disabled(!row.answers)
                }
                if row.workspace == nil {
                    Button("Link to Provider…") { show(.link) }
                }
            }
            if actions.delete || actions.remove {
                Divider()
                if actions.delete {
                    Button("Delete \(name)…", role: .destructive) { askDelete() }
                } else {
                    Button("Remove \(name)…") { removing = true }
                }
            }
        }
        .confirmationDialog("Delete \(name)?", isPresented: $deleting, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { Task { await model.deleteMachine(host) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let row {
                Text(MachineRowActions.deleteMessage(row, sessions: model.work.agents.filter { $0.host == host }.count,
                                                     preview: deleteWork, asking: askingWork))
            }
        }
        .sheet(item: $sheet, onDismiss: { control?.stop(); control = nil }) { shown in
            sheetView(shown).paperSheet()
        }
        .confirmationDialog("Remove \(name)?", isPresented: $removing, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { Task { await model.removeMachine(host) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It stops connecting, and every window and device stops seeing it. Its agents are left running where they are.")
        }
        .confirmationDialog("Stop \(name)?", isPresented: Binding(get: { !stoppingNames.isEmpty },
                                                                  set: { if !$0 { stoppingNames = [] } }),
                            titleVisibility: .visible) {
            Button("Stop") { Task { _ = await model.stopHost(host, confirmed: true) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(MachineRow.list(stoppingNames)) \(stoppingNames.count == 1 ? "is" : "are") working there. Stopping the machine stops them.")
        }
    }

    /// "Claude (fix-login) and Codex (docs)".
    static func list(_ names: [String]) -> String {
        guard names.count > 1 else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " and " + names.last!
    }

    /// Stop asks only when sessions run there: the control plane says who.
    private func stop() async {
        if let names = await model.stopHost(host) { stoppingNames = names }
    }

    /// Delete asks at once, and the machine is asked meanwhile which worktrees have work not pushed.
    private func askDelete() {
        deleteWork = nil
        askingWork = true
        deleting = true
        Task {
            deleteWork = await model.deletePreview(host)
            askingWork = false
        }
    }

    private func show(_ shown: MachineSheet) {
        if shown.needsControl {
            control = ControlConfig.endpoint.flatMap { ControlSettingsModel(endpoint: $0) }
            guard control != nil else { return }
        }
        sheet = shown
    }

    @ViewBuilder
    private func sheetView(_ shown: MachineSheet) -> some View {
        if let row = model.hosts.controlRows[host] {
            switch shown {
            case .backups: HostBackupsSheet(host: row)
            case .processes: MachineProcessesSheet(host: row)
            case .folders:
                if let control {
                    ChooseFoldersSheet(host: host, hostName: model.hosts.label(host), paths: control.suggestedPaths)
                        .task { await control.start() }
                }
            case .update:
                if let control {
                    ControlAddServerSheet(control: control, updating: row).task { await control.start() }
                }
            case .link:
                if let control {
                    LinkWorkspaceSheet(control: control, host: row).task { await control.start() }
                }
            }
        }
    }
}

/// A sheet a machine's row opens from its menu (#3979).
enum MachineSheet: String, Identifiable {
    case update, folders, backups, processes, link
    var id: String { rawValue }
    /// Opened with the control plane's model, as Settings ▸ Machines had them.
    var needsControl: Bool { self == .update || self == .folders || self == .link }
}

extension AppModel {
    /// A machine's most urgent need, as its row says it (#3764). Sign-in is what its runtimes
    /// last said: This Mac's are always read, a server's when its page was opened.
    func need(of host: MachineRef) -> MachineNeed? {
        MachineNeed.most(row: hosts.controlRows[host], offline: hostUnreachable(host),
                         runtimes: runtimes(on: host), disks: diskAlarms(host), capacity: capacityLevel(host))
    }

    /// The machine's capacity level, as it last pushed it (#4748); nil while it is unreachable,
    /// where what it last said is old.
    func capacityLevel(_ host: MachineRef) -> DaemonAPI.CapacityLevel? {
        hostUnreachable(host) ? nil : work.capacity[host]?.level
    }

    /// Whether a disk on the machine is low or almost full, as its page says (#3626, #3628).
    func diskWarns(_ host: MachineRef) -> Bool {
        diskAlarms(host).contains { $0.level != .ok }
    }

    private func diskAlarms(_ host: MachineRef) -> [DiskAlarm] {
        host == .mac ? work.disk.alarms : serverDisks[host]?.alarms ?? []
    }
}

/// A machine New Machine made that has not joined yet (#4610), as the web page's MakingRow:
/// an amber, pulsing cloud and *Making…* while the control plane waits for it; red with the
/// reason, and Delete, once the control plane gave up. Nil while providers/create has not
/// answered yet: a row at once, named once the provider names it.
struct MakingMachineRow: View {
    @Environment(AppModel.self) private var model
    let making: MachineMaking?
    @State private var deleting = false

    var body: some View {
        let name = making?.name ?? "New machine"
        let line = making?.line ?? "Making…"
        let gaveUp = making?.notJoined != nil
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            MachineIconView(symbol: "cloud", icon: gaveUp ? .failure : .busy)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).foregroundStyle(.primary).lineLimit(1)
                Text(line)
                    .appText(.fine)
                    .foregroundStyle(gaveUp ? StateTint.failure.style(or: .secondary) : AnyShapeStyle(.secondary))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
        }
        .help("\(name): \(line)")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(name), \(line)")
        // A full swipe never deletes: Delete asks first.
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if gaveUp {
                Button("Delete", systemImage: "trash", role: .destructive) { deleting = true }
            }
        }
        .contextMenu {
            if gaveUp {
                Button("Delete \(name)…", role: .destructive) { deleting = true }
            }
        }
        .confirmationDialog("Delete \(name)?", isPresented: $deleting, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let making { Task { await model.deleteWorkspace(making.provider, workspace: making.workspace) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(making?.deleteMessage ?? "")
        }
    }
}
