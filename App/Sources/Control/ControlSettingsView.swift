import AgentsKitCore
import AppKit
import SwiftUI

/// Settings ▸ Control plane (058, frames D–G): where it runs, the machines it reaches and
/// the screens that reach it. One row in the rail; its pages are listed in the pane (#1076).
enum ControlPage: Hashable {
    case overview, hosts, providers, clients

    var title: String {
        switch self {
        case .overview: "Overview"
        case .hosts: "Machines"
        case .providers: "Machine Providers"
        case .clients: "Clients"
        }
    }
}

struct ControlSettingsView: View {
    let control: ControlSettingsModel
    let page: ControlPage

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                // Where the page is in the rail (#1759, #2157): Machines, or Control plane.
                HStack(spacing: 6) {
                    Text(page == .hosts ? SettingsScope.machines.title : SettingsScope.controlPlane.title)
                        .appText(.reading).fontWeight(.semibold)
                    Text("›").foregroundStyle(.secondary)
                    Text(page.title).appText(.reading).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
                if !control.isReachable {
                    Text("Can’t reach the control plane at \(control.whereItIs). What it last said is shown.")
                        .appText(.supporting).tinted(.attention)
                        .fixedSize(horizontal: false, vertical: true)
                }
                switch page {
                case .overview: ControlOverviewPage(control: control)
                case .hosts: ControlHostsPage(control: control)
                case .providers: ControlProvidersPage(control: control)
                case .clients: ControlClientsPage(control: control)
                }
                if let problem = control.problem {
                    Text(problem).appText(.supporting).tinted(.failure)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: 640, alignment: .leading)
            .padding(20)
        }
    }
}

// MARK: - The pieces every page uses

/// A raised card of rows with a rule between them, as frames D–F draw each list.
struct ControlCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Paper.raised, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Paper.rule, lineWidth: 1))
    }
}

/// One row: a dot, a title with its line under it, and what may be done at the end.
enum ControlDot { case online, offline, attention, none }

struct ControlRow<Trailing: View>: View {
    let dot: ControlDot
    let title: String
    var chip: String?
    var chipTone: SharedChip.Tone = .source
    let detail: String
    /// The detail as drawn, when part of it is emphasised (frame N's relaying Mac).
    var detailText: Text?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            dotView.frame(width: 10)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title).appText(.reading).fontWeight(.semibold)
                    if let chip { SharedChip(text: chip, tone: chipTone) }
                }
                (detailText ?? Text(detail)).appText(.supporting).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel([title, chip, detail].compactMap { $0 }.joined(separator: ", "))
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder private var dotView: some View {
        switch dot {
        case .online: Circle().frame(width: 8, height: 8).tinted(.vouched)
        case .offline: Circle().frame(width: 8, height: 8).foregroundStyle(.tertiary)
        case .attention: Circle().frame(width: 8, height: 8).tinted(.attention)
        case .none: Color.clear.frame(width: 8, height: 8)
        }
    }
}

// MARK: - D · Overview

struct ControlOverviewPage: View {
    @Environment(AppModel.self) private var model
    let control: ControlSettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if control.isOnThisMac { ControlBrowserCard(control: control) }
            ControlCard {
                ControlRow(dot: control.isReachable ? .online : .offline,
                           title: control.isOnThisMac ? "This Mac" : (control.status?.name ?? "Control plane"),
                           chip: control.isOnThisMac ? "you are here" : nil,
                           detail: runningLine) {
                    if control.isOnThisMac {
                        Button("Restart") { Task { await control.restart() } }.buttonStyle(.paper)
                    }
                }
                Divider()
                ControlRow(dot: .none, title: "Reachable away from home",
                           detail: reachableLine) {
                    Text(control.publicAddress != nil || control.status?.awayFromHome == true ? "On" : "Off")
                        .appText(.reading)
                        .foregroundStyle(.secondary)
                }
                // This Mac's host trying to join, as it says it (#113): not only in daemon.log.
                // No membership is said even before a dial has failed. A process that is
                // not writing a join, on this Mac's own plane, is down (#303).
                if let join = control.status?.thisMacHost, !join.member || join.failed {
                    Divider()
                    ControlRow(dot: .attention, title: "This Mac as a machine", detail: join.summary) {
                        Text(join.member ? "Reconnecting" : "Not joined yet")
                            .appText(.reading)
                            .foregroundStyle(.secondary)
                    }
                } else if control.isOnThisMac, control.thisMacHost == nil, control.status?.thisMacHost == nil {
                    Divider()
                    ControlRow(dot: .attention, title: "This Mac as a machine",
                               detail: "It isn’t running, so it has not joined. Open Agents Host: it says why, and Repair there starts it again.") {
                        Text("Not running").appText(.reading).foregroundStyle(.secondary)
                    }
                }
            }
            if control.isOnThisMac {
                Text("While this Mac sleeps, no window or device can reach any of your agents. Agents on other machines keep working.")
                    .appText(.supporting).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            SharedSectionLabel("Machines")
            ControlCard {
                ControlRow(dot: .none, title: "\(count(control.hosts.count, "machine")) · \(control.onlineCount) online",
                           detail: control.hosts.map(hostName).joined(separator: ", ")) {
                    Button("Show") { model.settingsPaneAsked = .machines }.buttonStyle(.link)
                }
            }
            SharedSectionLabel("Clients")
            ControlCard {
                ControlRow(dot: .none,
                           title: count(control.clients.count, "client"),
                           detail: control.clients.map { $0.id == control.status?.you ? "This window" : $0.name }
                               .joined(separator: ", ")) {
                    Button("Show") { model.settingsPaneAsked = .clients }.buttonStyle(.link)
                }
            }
        }
    }

    private var reachableLine: String {
        // On the internet (#1498): every device reaches it from any network, with no relay.
        if let address = control.publicAddress { return "On the internet at \(address): devices reach it from any network" }
        if control.status?.awayFromHome == true { return "Through your iCloud account, sealed to each device" }
        // A control plane with no Mac relaying for it, a server's alone included, gets one
        // from Agents Host on any Mac (#824).
        return "Off: devices reach it on this network only. Turn on Relay for my devices in Agents Host on a Mac."
    }

    private var runningLine: String {
        guard let status = control.status else { return "Not answering" }
        var parts = ["agents-control \(status.version)"]
        // Its address, unless its name already says it.
        if let address = control.publicAddress, address != status.name { parts.append(address) }
        if let started = status.startedAt {
            parts.append("running since \(started.formatted(date: .omitted, time: .shortened))")
        }
        // The port it listens on is its own; on the internet, a proxy in front of it has
        // the one devices use (#1498).
        if control.publicAddress == nil, let port = status.port { parts.append("port \(port)") }
        // This window too old for it (#1748), on a line of its own.
        return ([parts.joined(separator: " · ")] + [UpdateWords.appMissing(status)].compactMap { $0 }).joined(separator: "\n")
    }

    private func hostName(_ host: DaemonAPI.ControlMachine) -> String {
        let name = host.machineID == MachineID.current && host.runsAgents ? "This Mac" : host.name
        return host.state == "online" ? name : "\(name) (\(UpdateWords.state(host)))"
    }
}

/// The page in a browser on this Mac, first on the page so it is found (#109): what the
/// control plane says of it, never just the address (071 R3), and Open in Browser beside it.
struct ControlBrowserCard: View {
    let control: ControlSettingsModel
    @State private var opening = false

    var body: some View {
        ControlCard {
            ControlRow(dot: web?.served == false ? .attention : .none,
                       title: "Use Agents in Safari or Chrome on this Mac", detail: detail) {
                if web?.served == true {
                    Button("Open in Browser") {
                        opening = true
                        Task {
                            control.problem = await control.openInBrowser()
                            opening = false
                        }
                    }
                    .buttonStyle(.paper)
                    .disabled(opening)
                } else {
                    Text("Not serving").appText(.reading).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var web: DaemonAPI.WebRemoteStatus? { control.status?.web }

    private var detail: String {
        guard let web else { return BrowserOpening.offWords }
        return web.served ? "\(web.summary) The first time, it pairs that browser too." : "\(web.summary) Try again in Agents Host."
    }
}

func count(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }

// MARK: - E · Hosts

struct ControlHostsPage: View {
    @Environment(AppModel.self) private var model
    let control: ControlSettingsModel
    @State private var removing: DaemonAPI.ControlMachine?
    @State private var addingMachine = false
    @State private var choosing: DaemonAPI.ControlMachine?
    /// Link to Machine… (#691, L5).
    @State private var linking: DaemonAPI.ControlMachine?
    /// Stop, asked first while agents are working there (L2), with who they are.
    @State private var stopping: DaemonAPI.ControlMachine?
    @State private var stoppingNames: [String] = []
    /// Delete Machine… (US5, L9).
    @State private var deleting: DaemonAPI.ControlMachine?
    /// Backups… (#1815): the host's own backups page.
    @State private var backingUp: DaemonAPI.ControlMachine?
    /// Update… (#1766): a host that needs an update, updated over ssh.
    @State private var updating: DaemonAPI.ControlMachine?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ControlCard {
                if let mac = control.thisMacHost {
                    // This Mac's host has no buttons but this one (the look gate's
                    // decision; #656 asked for folders to be chosen here too).
                    ControlRow(dot: dot(mac), title: "This Mac", detail: thisMacLine(mac)) {
                        chooseFolders(mac)
                    }
                }
                ForEach(control.otherHosts) { host in
                    Divider()
                    ControlRow(dot: dot(host), title: host.name, detail: line(host)) {
                        // One main action and a menu of the rest (#691, L2).
                        HStack(spacing: 8) {
                            mainAction(host)
                            hostMenu(host)
                        }
                        // The buttons keep their one line; the line beside them wraps.
                        .fixedSize()
                    }
                }
                // Installed over a tunnel and not joined yet (#660): no host row yet, so
                // this is where ssh's reason shows once Add a Machine is closed.
                ForEach(control.status?.unjoinedTunnels ?? [], id: \.name) { pending in
                    Divider()
                    ControlRow(dot: pending.tunnel.up ? .offline : .attention, title: pending.name,
                               detail: unjoinedLine(pending.tunnel)) { EmptyView() }
                }
            }
            // One sheet, a provider first (#2131): a server and a code are its other two ways.
            Button(AddMachine.Words.menuItem) { addingMachine = true }.buttonStyle(.paper)
            Text("A machine comes from a machine provider, or a Linux machine runs one command, or is installed over ssh as you log in from Terminal, through an ssh tunnel when it can’t reach this Mac. Either way it connects out, so nothing has to reach it. Another Mac joins with a code. " + AddMachine.Words.machinesFoot)
                .appText(.supporting).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SharedSectionLabel("Auto-detect")
            FolderDetectionCard(control: control)
        }
        .sheet(isPresented: $addingMachine) { AddMachineSheet(control: control).paperSheet() }
        .sheet(item: $updating) { host in ControlAddServerSheet(control: control, updating: host).paperSheet() }
        .sheet(item: $linking) { host in
            LinkWorkspaceSheet(control: control, host: host).paperSheet()
        }
        .confirmationDialog(stopping.map { "Stop \($0.name)?" } ?? "",
                            isPresented: Binding(get: { stopping != nil }, set: { if !$0 { stopping = nil } }),
                            titleVisibility: .visible, presenting: stopping) { host in
            Button("Stop") {
                Task {
                    // Asked for its wake-up call only: who is working there is asked next.
                    guard stoppingNames.isEmpty else { _ = await control.stop(host.id, confirmed: true); return }
                    guard let names = await control.stop(host.id) else { return }
                    stoppingNames = names
                    stopping = host
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { host in
            Text(stopWords(host))
        }
        .sheet(item: $backingUp) { host in
            HostBackupsSheet(host: host).paperSheet()
        }
        .sheet(item: $choosing) { host in
            ChooseFoldersSheet(host: host.id, hostName: host.id == control.thisMacHost?.id ? "This Mac" : host.name,
                                paths: control.suggestedPaths).paperSheet()
        }
        .confirmationDialog(deleting.map { "Delete \($0.workspace?.workspaceName ?? $0.name)?" } ?? "",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { host in
            Button("Delete", role: .destructive) { Task { await control.deleteMachine(host.id) } }
            Button("Cancel", role: .cancel) {}
        } message: { host in
            Text(deleteWords(host))
        }
        .confirmationDialog(removing.map { "Remove \($0.name)?" } ?? "",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible, presenting: removing) { host in
            Button("Remove", role: .destructive) { Task { await control.remove(host.id) } }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("It stops connecting, and every window and device stops seeing it. Its agents are left running where they are.")
        }
    }

    private func chooseFolders(_ host: DaemonAPI.ControlMachine) -> some View {
        Button("Choose Folders…") { choosing = host }
            .buttonStyle(.paper)
            .disabled(!host.answers)
            .help(host.answers ? "Pick folders on it to add as folders." : "It has to be online to be asked.")
    }

    private func dot(_ host: DaemonAPI.ControlMachine) -> ControlDot {
        if host.workspace?.problem != nil { return .attention }
        return switch host.state {
        case "online": .online
        case "needsUpdate", "failed": .attention
        default: .offline
        }
    }

    // MARK: A linked host's workspace (#691, L2)

    /// Start or Stop for a linked host, while nothing is under way; Check again for any other.
    @ViewBuilder
    private func mainAction(_ host: DaemonAPI.ControlMachine) -> some View {
        if let workspace = host.workspace {
            if host.state == "starting" || host.state == "stopping" {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(Self.underWay(host)).appText(.supporting).foregroundStyle(.secondary)
                }
            } else if host.state == "online" || !workspace.canStart {
                Button("Stop") {
                    // The control plane knows who is working there, from the host itself (US4).
                    Task {
                        // Said first when it will start again for a schedule (#1004 FR-010).
                        if workspace.wakeAt != nil {
                            stoppingNames = []
                            stopping = host
                            return
                        }
                        guard let names = await control.stop(host.id) else { return }
                        stoppingNames = names
                        stopping = host
                    }
                }
                .buttonStyle(.paper)
                .disabled(!workspace.canStop)
                .help("Stops \(workspace.workspaceName) at \(workspace.providerName).")
            } else {
                Button("Start") { Task { await control.start(host.id) } }
                    .buttonStyle(.paper)
                    .help("Starts \(workspace.workspaceName) at \(workspace.providerName).")
            }
        } else {
            Button("Check again") { Task { await control.checkAgain(host.id) } }.buttonStyle(.paper)
        }
    }

    /// What a start or stop under way says: a delete's backup is a stop of its own (#1815).
    static func underWay(_ host: DaemonAPI.ControlMachine) -> String {
        if host.state == "starting" { return "Starting…" }
        return host.workspace?.phase == "backing up" ? "Backing up to delete…" : "Stopping…"
    }

    private func hostMenu(_ host: DaemonAPI.ControlMachine) -> some View {
        Menu {
            // Older than the control plane needs (#1748): updated over ssh, as installed (#1766).
            if host.state == "needsUpdate" {
                Button("Update…") { updating = host }
                Divider()
            }
            // A relay runs no agents, so it has no folders, and nothing to back up.
            if host.relay == nil {
                Button("Choose Folders…") { choosing = host }.disabled(!host.answers)
                if model.host(host.id, has: Capability.backups1) {
                    Button("Backups…") { backingUp = host }.disabled(!host.answers)
                }
            }
            if host.workspace != nil {
                Button("Check again") { Task { await control.checkAgain(host.id) } }
            }
            if host.relay == nil, control.providersHere {
                Divider()
                if let workspace = host.workspace {
                    Button("Unlink from \(workspace.workspaceName)") { Task { await control.unlink(host.id) } }
                    if control.canDeleteWorkspace(host) {
                        Button("Delete Machine…", role: .destructive) { deleting = host }
                    }
                    Toggle("Start when used", isOn: Binding(
                        get: { workspace.startWhenUsed },
                        set: { on in Task { await control.setWorkspaceOptions(host.id, startWhenUsed: on) } }))
                    Toggle("Start for scheduled workflows", isOn: Binding(
                        get: { workspace.startForSchedules ?? true },
                        set: { on in Task { await control.setWorkspaceOptions(host.id, startForSchedules: on) } }))
                    Picker("Stop when idle", selection: Binding(
                        get: { workspace.stopWhenIdleMinutes ?? 0 },
                        set: { minutes in Task { await control.setWorkspaceOptions(host.id, stopWhenIdleMinutes: minutes) } })) {
                        Text("Off").tag(0)
                        Text("After 15 minutes").tag(15)
                        Text("After 30 minutes").tag(30)
                        Text("After 1 hour").tag(60)
                        Text("After 2 hours").tag(120)
                    }
                } else {
                    Button("Link to Provider…") { linking = host }.disabled(control.providers.isEmpty)
                }
            }
            // Git access it uses of a Mac's, each taken back on its own (#1122).
            if let lent = host.gitFrom, !lent.isEmpty {
                Divider()
                ForEach(lent.keys.sorted(), id: \.self) { server in
                    Button(GitLendWords.revoke(server)) {
                        Task { await control.revokeGit(host.id, from: lent[server]!, server: server) }
                    }
                }
            }
            Divider()
            Button("Remove…") { removing = host }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("More for \(host.name)")
    }

    /// What Delete Machine… loses (L9): the workspace and its disk, and the host with its
    /// agents, and whether it backs up first (#1815).
    private func deleteWords(_ host: DaemonAPI.ControlMachine) -> String {
        let agents = model.work.agents.filter { $0.host == host.id }.count
        let workspace = host.workspace.map { "\($0.workspaceName) at \($0.providerName)" } ?? "The machine"
        // An online host backs up first (#1815); an offline one keeps the backups it made.
        let backup = host.answers ? " It is backed up first, and deleted once the backup is made."
            : " It is offline, so it is not backed up first; the backups it made are kept."
        return "\(workspace) and everything on its disk are deleted, and \(host.name) is removed from your machines"
            + (agents == 0 ? "." : " with its \(agents == 1 ? "agent" : "\(agents) agents").") + backup
    }

    static func minutes(_ minutes: Int) -> String {
        minutes == 60 ? "1 hour" : minutes % 60 == 0 ? "\(minutes / 60) hours" : "\(minutes) minutes"
    }

    /// "Claude (fix-login) and Codex (docs)".
    static func list(_ names: [String]) -> String {
        guard names.count > 1 else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " and " + names.last!
    }

    /// Stop's confirmation: who is working there, and when it starts again (#1004 FR-010).
    private func stopWords(_ host: DaemonAPI.ControlMachine) -> String {
        var words: [String] = []
        if !stoppingNames.isEmpty {
            words.append("\(Self.list(stoppingNames)) \(stoppingNames.count == 1 ? "is" : "are") working there. Stopping the machine stops them.")
        }
        if let workspace = host.workspace, let wake = OfflineWords.wakeLine(workspace) {
            words.append("\(wake) again.")
        }
        return words.joined(separator: " ")
    }

    /// The host's workflows that run on a clock (L8): they don't run while it is stopped.
    private func scheduledWorkflows(_ host: MachineRef) -> Int {
        model.work.folders.filter { $0.host == host }
            .flatMap { model.work.workflows(in: $0.folder.folder) }
            .filter { !$0.isArchived && $0.isEnabled && !$0.workflow.schedules.isEmpty }
            .count
    }

    private func thisMacLine(_ host: DaemonAPI.ControlMachine) -> String {
        let folders = model.work.folders.filter { $0.host == host.id }.count
        let working = model.work.agents.filter { $0.host == host.id && ($0.state == .running || $0.state == .starting) }.count
        var parts = [host.platform.replacingOccurrences(of: " ", with: " · "), UpdateWords.version(host),
                     count(folders, "folder")]
        if working > 0 { parts.append("\(count(working, "agent")) working") }
        if host.state != "online" { parts.insert(UpdateWords.state(host), at: 0) }
        return ([parts.joined(separator: " · ")] + [UpdateWords.missing(host, controlVersion: control.status?.version)].compactMap { $0 })
            .joined(separator: "\n")
    }

    private func unjoinedLine(_ tunnel: DaemonAPI.MachineTunnel) -> String {
        tunnel.up
            ? "Not joined yet · connects through an ssh tunnel, which is up"
            : "Not joined yet · ssh tunnel down\(tunnel.problem.map { ": \($0)" } ?? "") · tried again by itself"
    }

    /// Its line, and what it may use of a Mac's (#1122) on one of its own.
    private func line(_ host: DaemonAPI.ControlMachine) -> String {
        let uses = GitLendWords.uses(host) { lender in
            lender == control.thisMacHost?.id ? nil : (control.hosts.first { $0.id == lender }?.name ?? lender.rawValue)
        }
        return [baseLine(host), UpdateWords.missing(host, controlVersion: control.status?.version), uses]
            .compactMap { $0 }.joined(separator: "\n")
    }

    private func baseLine(_ host: DaemonAPI.ControlMachine) -> String {
        // agents-relay (T096): it runs no agents, so the rest of the line is not its.
        if host.relay != nil {
            let state = host.state == "online" ? "" : "\(UpdateWords.state(host)) · "
            return state + (host.relay == true ? "Relays your devices through iCloud" : "Relaying switched off")
        }
        var parts: [String] = []
        if host.state != "online" { parts.append(UpdateWords.state(host)) }
        if !host.platform.isEmpty { parts.append(host.platform.replacingOccurrences(of: " ", with: " · ")) }
        if !host.version.isEmpty { parts.append(UpdateWords.version(host)) }
        if let workspace = host.workspace {
            // Linked (#691, L2): where it runs, and what Agents does with it, on a line of its own.
            parts.append("\(workspace.providerName): \(workspace.workspaceName)")
            if host.state != "online", let cost = workspace.cost { parts.append(cost) }
            var second: [String] = []
            if let problem = workspace.problem { second.append(problem) }
            if let minutes = workspace.stopWhenIdleMinutes { second.append("Stops after \(Self.minutes(minutes)) idle") }
            if workspace.startWhenUsed { second.append("Starts when used") }
            // Its wake-up call (#1004 FR-007), or that its schedule keeps it up (edge case).
            if host.state != "online", let wake = OfflineWords.wakeLine(workspace) { second.append(wake) }
            if host.state == "online", let up = OfflineWords.staysUpLine(workspace) { second.append(up) }
            if !workspace.current { second.append("\(workspace.providerName) didn’t answer its last list") }
            var lines = [parts.joined(separator: " · ")]
            if !second.isEmpty { lines.append(second.joined(separator: " · ")) }
            // L8: a host that stops when idle doesn't run its scheduled workflows while stopped,
            // unless it is started for them (#1004 FR-008, FR-009, FR-011).
            let started = (workspace.startForSchedules ?? true) && workspace.tellsSchedule == true
            let scheduled = workspace.stopWhenIdleMinutes == nil || started ? 0 : scheduledWorkflows(host.id)
            if scheduled > 0 {
                lines.append("⚠ \(scheduled == 1 ? "1 scheduled workflow here doesn’t" : "\(scheduled) scheduled workflows here don’t") run while it is stopped.")
            }
            return lines.joined(separator: "\n")
        }
        if let tunnel = host.tunnel {
            // Behind a bastion (#435): it dials through a session this Mac holds.
            parts.append(tunnel.up ? "connects through an ssh tunnel"
                                   : "ssh tunnel down\(tunnel.problem.map { ": \($0)" } ?? "")")
        } else {
            parts.append("connects out")
        }
        // The sign-in relay goes to this Mac's host through the control plane (T091), on
        // any network (#1498).
        parts.append("Sign-in relay goes to this Mac through the control plane")
        return parts.joined(separator: " · ")
    }
}

/// Auto-detect (#429, #656): where the folders picker looks on a host. It adds nothing.
struct FolderDetectionCard: View {
    let control: ControlSettingsModel
    /// The paths as typed, one a line; saved with Save.
    @State private var text = ""
    /// What was last put in `text` from the control plane.
    @State private var shown = ""

    var body: some View {
        let detection = control.folderDetection
        ControlCard {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Suggest folders on a machine", isOn: Binding(
                    get: { detection.enabled },
                    set: { on in Task { await control.setFolderDetection(FolderDetection(enabled: on, paths: detection.paths)) } }))
                TextField("Paths", text: $text, axis: .vertical)
                    .lineLimit(3...10)
                    .textFieldStyle(.roundedBorder).appText(.code)
                    .accessibilityLabel("Paths to look in, one a line")
                    .disabled(!detection.enabled)
                HStack(spacing: 8) {
                    Button("Save") {
                        text = paths.joined(separator: "\n")
                        shown = text
                        Task { await control.setFolderDetection(FolderDetection(enabled: detection.enabled, paths: paths)) }
                    }
                    .buttonStyle(.paper)
                    .disabled(paths == detection.paths)
                    Button("Use the Defaults") { text = FolderDetection.defaultPaths.joined(separator: "\n") }
                        .buttonStyle(.paper)
                        .disabled(text == FolderDetection.defaultPaths.joined(separator: "\n"))
                }
                .disabled(!detection.enabled)
            }
            .padding(16)
        }
        Text("When a machine joins, and from Choose Folders… on any machine, each git repository directly inside these paths is listed, unticked. Only the ones you tick become folders, and you can add any other folder by its path. ~ is the machine’s own home.")
            .appText(.supporting).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .onAppear(perform: load)
            .onChange(of: detection.paths) { _, _ in load() }
    }

    private var paths: [String] {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// The saved paths, unless something has been typed over what was last shown.
    private func load() {
        let saved = control.folderDetection.paths.joined(separator: "\n")
        guard text == shown else { return }
        text = saved
        shown = saved
    }
}

// MARK: - G · Pair a Mac, and Add by Code

/// Frame G: the code as text, since a Mac has no camera; and the same sheet for a host's
/// code. Every client may do everything (#111), so there is nothing to choose first.
struct CodeSheet: View {
    /// A browser is a client like a Mac: on this Mac, or anywhere at the page on the control
    /// plane's own domain (071, frame E; #1459).
    enum Purpose { case mac, browser, host }

    @Environment(\.dismiss) private var dismiss
    let control: ControlSettingsModel
    let purpose: Purpose
    @State private var shown: DaemonAPI.ControlCodeShown?
    /// Who was there when the code was made, so whoever it lets in can be named.
    @State private var before: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).appText(.reading).fontWeight(.semibold)
            if let joined {
                Text("\(joined) joined with this code. It can’t be used again.")
                    .appText(.reading)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let shown {
                Text(shown.text)
                    .appText(.code)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Paper.raised, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Paper.rule, lineWidth: 1))
                    // One element of its own: a label on the selectable Text overflows the stack (#1724).
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Code")
                    .accessibilityValue(shown.text)
                HStack(alignment: .firstTextBaseline) {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(instructions(until: shown.expires, now: context.date))
                            .appText(.supporting).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(shown.text, forType: .string)
                    }
                    .buttonStyle(.paper)
                }
            } else {
                ProgressView().controlSize(.small)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 560)
        .task {
            before = members
            shown = await control.startCode(forHost: purpose == .host, browser: purpose == .browser)
        }
        .onDisappear { Task { await control.stopCodes() } }
    }

    private var title: String {
        switch purpose {
        case .mac: "Pair a Mac"
        case .browser: "Add a Browser"
        case .host: "Add a machine by code"
        }
    }

    /// The hosts or clients there are now, by id.
    private var members: Set<String> {
        purpose == .host ? Set(control.hosts.map(\.id.rawValue)) : Set(control.clients.map(\.id.uuidString))
    }

    /// Whoever arrived since the code was made: the code let them in, and is spent.
    private var joined: String? {
        guard shown != nil else { return nil }
        if purpose == .host {
            return control.hosts.first { !before.contains($0.id.rawValue) }?.name
        }
        return control.clients.first { !before.contains($0.id.uuidString) }?.name
    }

    private func instructions(until expires: Date, now: Date) -> String {
        let left = max(0, Int(expires.timeIntervalSince(now)))
        let time = left == 0 ? "It has run out; close this and ask again." : "It works once, for \(left / 60):\(String(format: "%02d", left % 60))."
        switch purpose {
        case .mac:
            return "On the other Mac, open Agents, choose Connect to a control plane and paste this. That Mac can then do all this window can. \(time)"
        case .browser:
            return "\(browserWhere) That browser can then do all this window can. \(time)"
        case .host:
            return "On the other machine, start its agents with agentsd --control-code and this code. \(time)"
        }
    }

    /// Where to paste a browser's code: the page on the control plane's own domain, for a
    /// browser anywhere (#1459), and the page on this Mac while it is served, else why it
    /// isn't, as the Overview's row says (071 R3).
    private var browserWhere: String {
        let anywhere = control.status?.publicWeb
        guard let web = control.status?.web else {
            if let anywhere { return "In any browser, open \(anywhere) and paste it in." }
            return "Turn on Serve Agents to browsers on this Mac in Agents Host first."
        }
        let here = web.served ? "On this Mac, open \(web.address) and paste it in."
            : "\(web.summary) Try again in Agents Host, then open \(web.address) on this Mac and paste it in."
        guard let anywhere else { return here }
        return "In any browser, open \(anywhere) and paste it in. \(here)"
    }
}

/// A server's backups (#1815), from its menu: the same section as Settings ▸ Machines ▸ This Mac ▸ Backups,
/// sent to that host.
private struct HostBackupsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let host: DaemonAPI.ControlMachine

    var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            HostBackupsView(client: model.client(for: host.id), hostName: host.name)
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
                .padding()
        }
        .frame(width: 520, height: 480)
    }
}
