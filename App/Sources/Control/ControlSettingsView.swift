import AgentsKitCore
import AppKit
import SwiftUI

/// Settings ▸ Control plane (058, frames D–G): where it runs, the machines it reaches and
/// the screens that reach it. One row in the rail; its pages are listed in the pane (#1076).
enum ControlPage: Hashable {
    /// Auto-detect is Machines' page (#1759): the machines themselves are in the sidebar (#3975).
    case overview, autoDetect, providers, clients

    var title: String {
        switch self {
        case .overview: "Overview"
        case .autoDetect: "Auto-detect"
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
                    Text(page == .autoDetect ? SettingsScope.machines.title : SettingsScope.controlPlane.title)
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
                case .autoDetect: FolderDetectionCard(control: control)
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
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            dotView.frame(width: 10)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title).appText(.reading).fontWeight(.semibold)
                    if let chip { SharedChip(text: chip, tone: chipTone) }
                }
                Text(detail).appText(.supporting).foregroundStyle(.secondary)
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
            if let host = HostScenes.model { HostServeCard(host: host) }
            ControlCard {
                ControlRow(dot: control.isReachable ? .online : .offline,
                           title: control.isOnThisMac ? "This Mac" : (control.status?.name ?? "Control plane"),
                           chip: control.isOnThisMac ? "you are here" : nil,
                           detail: runningLine) {
                    if control.isOnThisMac {
                        Button("Restart") { Task { await restart() } }.buttonStyle(.paper)
                    }
                    ControlPlaneMoveButton(control: control)
                }
                Divider()
                ControlRow(dot: .none, title: "Reachable away from home",
                           detail: reachableLine) {
                    Text(control.publicAddress != nil ? "On" : "Off")
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
                               detail: "It isn’t running, so it has not joined. Settings ▸ Machines ▸ This Mac says why, and Repair there starts it again.") {
                        Button("Show") { model.settingsPaneAsked = .machines }.buttonStyle(.link)
                    }
                }
            }
            // Agents Host's control plane controls (#4227): moving it, and its store.
            if let host = HostScenes.model { HostControlPlaneCards(host: host) }
            if control.isOnThisMac {
                Text("While this Mac sleeps, no window or device can reach any of your agents. Agents on other machines keep working.")
                    .appText(.supporting).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // The machines themselves are managed in the sidebar (#3975): here, how many.
            SharedSectionLabel("Machines")
            ControlCard {
                ControlRow(dot: .none, title: "\(count(control.hosts.count, "machine")) · \(control.onlineCount) online",
                           detail: control.hosts.map(hostName).joined(separator: ", ")) { EmptyView() }
                // Installed over a tunnel and not joined yet (#660): no machine in the sidebar
                // yet, so this is where ssh's reason shows once Add a Machine is closed.
                ForEach(control.status?.unjoinedTunnels ?? [], id: \.name) { pending in
                    Divider()
                    ControlRow(dot: pending.tunnel.up ? .offline : .attention, title: pending.name,
                               detail: unjoinedLine(pending.tunnel)) { EmptyView() }
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

    /// The control plane on this Mac is a login item of this app's host side (#4230).
    private func restart() async {
        if let host = HostScenes.model { await host.restartControl(); await control.refresh(); return }
        await control.restart()
    }

    private var reachableLine: String {
        // On the internet (#1498): every device reaches it from any network.
        if let address = control.publicAddress { return "On the internet at \(address): devices reach it from any network" }
        return "Off: devices reach it on this network only."
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

    private func unjoinedLine(_ tunnel: DaemonAPI.MachineTunnel) -> String {
        tunnel.up
            ? "Not joined yet · connects through an ssh tunnel, which is up"
            : "Not joined yet · ssh tunnel down\(tunnel.problem.map { ": \($0)" } ?? "") · tried again by itself"
    }

    private func hostName(_ host: DaemonAPI.ControlMachine) -> String {
        let name = host.machineID == MachineID.current ? "This Mac" : host.name
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
        guard let web, !web.isOff else { return BrowserOpening.offWords }
        return web.served ? "\(web.summary) The first time, it pairs that browser too." : "\(web.summary) Try Again is beside Serve Agents to browsers on this Mac."
    }
}

func count(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }

// MARK: - E · Auto-detect

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
            return "Turn on Serve Agents to browsers on this Mac in Settings ▸ Control plane first."
        }
        let here = web.served ? "On this Mac, open \(web.address) and paste it in."
            : "\(web.summary) Press Try Again beside Serve Agents to browsers on this Mac in Settings ▸ Control plane, then open \(web.address) on this Mac and paste it in."
        guard let anywhere else { return here }
        return "In any browser, open \(anywhere) and paste it in. \(here)"
    }
}

/// A server's backups (#1815), from its menu: the same section as Settings ▸ Machines ▸ This Mac ▸ Backups,
/// sent to that host.
struct HostBackupsSheet: View {
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
