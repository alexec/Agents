import AgentsKitCore
import SwiftUI

/// One machine's page in the main window (#3626): the place to go for its status. A summary
/// first (#3743): its CPU, memory and worst disk on one line. Then the detail, most of it
/// closed until the person opens it: the disk that matters with the others folded, a row
/// per folder's worktrees (#3627), the runtimes installed there (#3629), resources only
/// when one is declared or held, and its processes (#3453). Read with
/// `machine/usage` when it opens and every few seconds while it is open, never otherwise.
/// The machine's settings stay in Settings ▸ Machines; Settings… goes there. The web page draws the same in Web/src/views/MachinePage.tsx.
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
                Button("Settings…") {
                    model.settingsMachineAsked = host
                    model.settingsPaneAsked = .machines
                    openSettings()
                }
                .help("\(name)’s sleep, backups and desktop control, in Settings ▸ Machines")
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

    /// "Is this machine OK?" in one line (#3743): CPU, memory and the worst disk, in its tint.
    @ViewBuilder
    private var summarySection: some View {
        Section {
            if let usage {
                HStack(spacing: 0) {
                    Text("CPU \(ProcessWords.cpu(usage.machine.cpuPercent)) · Memory \(ProcessWords.machineMemory(usage.machine))")
                    if let disk = headline {
                        Text(" · ")
                        Text(DiskSpace.summaryWords(disk))
                            .foregroundStyle(Self.tint(disk.level).style(or: .primary))
                            .help(disk.level == .ok ? disk.reading.volume : disk.line)
                    }
                }
                .monospacedDigit()
                .help(ProcessWords.machineCPU(usage.machine))
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
        withAnimation {
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

/// A machine's row under Machines in the sidebar (#3626): its name and its dot, and under it,
/// in grey, the most urgent thing it needs (#3764). The dot and the line say only the machine's
/// own state: its sessions do not roll up into it (#3973). Its menu and swipes start, stop,
/// delete or remove it, as the web page's rows do (#3974).
struct MachineRow: View {
    @Environment(AppModel.self) private var model
    let host: MachineRef
    let open: () -> Void
    @State private var deleting = false
    @State private var removing = false
    /// Stop, asked first while agents work there, with who they are.
    @State private var stoppingNames: [String] = []

    var body: some View {
        let name = model.hosts.label(host)
        let row = model.hosts.controlRows[host]
        let need = model.need(of: host)
        let words = need.map { MachineNeedWords.line($0, name: name, row: row) }
        let actions = MachineRowActions.of(row, isThisMac: host == .mac)
        HStack(alignment: .firstTextBaseline, spacing: 6) {
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
            MachineDotView(dot: MachineDot.of(row, online: !model.hostUnreachable(host),
                                              starting: model.hostsBeingStarted.contains(host)))
        }
        .help(words.map { "\(name): \($0)" } ?? (model.diskWarns(host)
            ? "\(name): a disk is low. Its CPU, memory, disks, worktrees, runtimes and resources"
            : "\(name): its CPU, memory, disks, worktrees, runtimes and resources"))
        .accessibilityElement(children: .contain)
        .accessibilityValue(words ?? "")
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
                Button("Delete", systemImage: "trash", role: .destructive) { deleting = true }
            } else if actions.remove {
                Button("Remove", systemImage: "minus.circle") { removing = true }.tint(.gray)
            }
        }
        .contextMenu {
            Button("Open", action: open)
            if actions.start {
                Divider()
                Button("Start") { Task { await model.startHost(host) } }
            } else if actions.stop {
                Divider()
                Button("Stop") { Task { await stop() } }
            }
            if actions.delete || actions.remove {
                Divider()
                if actions.delete {
                    Button("Delete \(name)…", role: .destructive) { deleting = true }
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
                Text(MachineRowActions.deleteMessage(row, sessions: model.work.agents.filter { $0.host == host }.count))
            }
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
            Text("\(ControlHostsPage.list(stoppingNames)) \(stoppingNames.count == 1 ? "is" : "are") working there. Stopping the machine stops them.")
        }
    }

    /// Stop asks only when sessions run there: the control plane says who.
    private func stop() async {
        if let names = await model.stopHost(host) { stoppingNames = names }
    }
}

/// A machine's dot (#3973): green online, amber and turning while it changes, grey and hollow
/// stopped, red offline, amber when it needs an update.
private struct MachineDotView: View {
    let dot: MachineDot

    var body: some View {
        Group {
            switch dot {
            case .online: Circle().tinted(.vouched)
            case .busy: SyncedSpinner(diameter: 8, color: StateTint.attention.color ?? .secondary)
            case .stopped: Circle().strokeBorder(.secondary, lineWidth: 1.2)
            case .offline: Circle().tinted(.failure)
            case .attention: Circle().tinted(.attention)
            }
        }
        .frame(width: 8, height: 8)
        .accessibilityHidden(true)
    }
}

/// The grey line under a machine's row (#3764), in the words the rest of the window says
/// them in: the sidebar foot's (OfflineWords), set-up's (HostProblem) and updates' (UpdateWords).
enum MachineNeedWords {
    static func line(_ need: MachineNeed, name: String, row: DaemonAPI.ControlMachine?) -> String {
        switch need {
        case .offline, .stopped: OfflineWords.footLine(name: name, row: row)
        case .setupFailed: HostProblem.installFailed("").sentence(name: name, label: name)
        case .disk(let disk): DiskSpace.needWords(disk)
        case .update: row.map(UpdateWords.state) ?? "Needs an update"
        case .signIn(let runtimes):
            "\(ListFormatter.localizedString(byJoining: runtimes)) \(runtimes.count == 1 ? "needs" : "need") sign-in"
        }
    }
}

extension AppModel {
    /// A machine's most urgent need, as its row says it (#3764). Sign-in is what its runtimes
    /// last said: This Mac's are always read, a server's when its page was opened.
    func need(of host: MachineRef) -> MachineNeed? {
        MachineNeed.most(row: hosts.controlRows[host], offline: hostUnreachable(host),
                         runtimes: runtimes(on: host), disks: diskAlarms(host))
    }

    /// Whether a disk on the machine is low or almost full, as its page says (#3626, #3628).
    func diskWarns(_ host: MachineRef) -> Bool {
        diskAlarms(host).contains { $0.level != .ok }
    }

    private func diskAlarms(_ host: MachineRef) -> [DiskAlarm] {
        host == .mac ? work.disk.alarms : serverDisks[host]?.alarms ?? []
    }
}
