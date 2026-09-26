import AgentsKit
import AgentsKitCore
import SwiftUI

/// Settings ▸ Control plane (058, frames D–G): where it runs, the machines it reaches and
/// the screens that reach it. One group in the rail, opening like Shared.
enum ControlPage: Hashable {
    case overview, hosts, clients

    var title: String {
        switch self {
        case .overview: "Overview"
        case .hosts: "Hosts"
        case .clients: "Clients"
        }
    }
}

struct ControlSettingsView: View {
    let control: ControlSettingsModel
    @Binding var page: ControlPage

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 6) {
                    Text("Control plane").appText(.reading).fontWeight(.semibold)
                    Text("›").foregroundStyle(.secondary)
                    Text(page.title).appText(.reading).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
                if !control.isReachable {
                    Text("Can’t reach the control plane at \(SharedFiles.tilde(control.root.path)). What it last said is shown.")
                        .appText(.supporting).tinted(.attention)
                        .fixedSize(horizontal: false, vertical: true)
                }
                switch page {
                case .overview: ControlOverviewPage(control: control, page: $page)
                case .hosts: ControlHostsPage(control: control)
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
    let detail: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            dotView.frame(width: 10)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title).appText(.reading).fontWeight(.semibold)
                    if let chip { SharedChip(text: chip, tone: .source) }
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
    let control: ControlSettingsModel
    @Binding var page: ControlPage

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
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
                           detail: control.status?.awayFromHome == true
                               ? "Through your iCloud account, sealed to each device"
                               : "Off: devices reach it on this network only") {
                    Text(control.status?.awayFromHome == true ? "On" : "Off")
                        .appText(.reading)
                        .foregroundStyle(.secondary)
                }
            }
            if control.isOnThisMac {
                Text("While this Mac sleeps, no window or device can reach any of your agents. Agents on servers keep working.")
                    .appText(.supporting).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            SharedSectionLabel("Hosts")
            ControlCard {
                ControlRow(dot: .none, title: "\(count(control.hosts.count, "host")) · \(control.onlineCount) online",
                           detail: control.hosts.map(hostName).joined(separator: ", ")) {
                    Button("Show") { page = .hosts }.buttonStyle(.link)
                }
            }
            SharedSectionLabel("Clients")
            ControlCard {
                ControlRow(dot: .none,
                           title: "\(count(control.clients.count, "client")) · \(count(control.operatorCount, "operator"))",
                           detail: control.clients.map { $0.id == control.status?.you ? "This window" : $0.name }
                               .joined(separator: ", ")) {
                    Button("Show") { page = .clients }.buttonStyle(.link)
                }
            }
        }
    }

    private var runningLine: String {
        guard let status = control.status else { return "Not answering" }
        var parts = ["agents-control \(status.version)"]
        if let started = status.startedAt {
            parts.append("running since \(started.formatted(date: .omitted, time: .shortened))")
        }
        if let port = status.port { parts.append("port \(port)") }
        return parts.joined(separator: " · ")
    }

    private func hostName(_ host: DaemonAPI.ControlHost) -> String {
        let name = host.machineID == MachineID.current ? "This Mac" : host.name
        return host.state == "online" ? name : "\(name) (\(host.state))"
    }
}

func count(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }

// MARK: - E · Hosts

struct ControlHostsPage: View {
    @Environment(AppModel.self) private var model
    let control: ControlSettingsModel
    @State private var removing: DaemonAPI.ControlHost?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ControlCard {
                if let mac = control.thisMacHost {
                    // This Mac's host has no buttons (the look gate's decision).
                    ControlRow(dot: dot(mac), title: "This Mac", detail: thisMacLine(mac)) { EmptyView() }
                }
                ForEach(control.otherHosts) { host in
                    Divider()
                    ControlRow(dot: dot(host), title: host.name, detail: line(host)) {
                        HStack(spacing: 8) {
                            Button("Check again") { Task { await control.checkAgain(host.id) } }.buttonStyle(.paper)
                            Button("Remove…") { removing = host }.buttonStyle(.paper)
                        }
                    }
                }
            }
            HStack(spacing: 8) {
                Button("Add a Server…") {}.buttonStyle(.paper).disabled(true)
                Button("Add by Code…") {}.buttonStyle(.paper).disabled(true)
            }
            Text("Adding a server or another Mac through the control plane comes next. Removing a host stops it connecting. Its agents are left running where they are.")
                .appText(.supporting).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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

    private func dot(_ host: DaemonAPI.ControlHost) -> ControlDot {
        switch host.state {
        case "online": .online
        case "needsUpdate", "failed": .attention
        default: .offline
        }
    }

    private func thisMacLine(_ host: DaemonAPI.ControlHost) -> String {
        let projects = model.work.projects.filter { $0.host == host.id }.count
        let working = model.work.agents.filter { $0.host == host.id && ($0.state == .running || $0.state == .starting) }.count
        var parts = [host.platform.replacingOccurrences(of: " ", with: " · "), "Agents \(host.version)",
                     count(projects, "project")]
        if working > 0 { parts.append("\(count(working, "agent")) working") }
        if host.state != "online" { parts.insert(host.state.capitalized, at: 0) }
        return parts.joined(separator: " · ")
    }

    private func line(_ host: DaemonAPI.ControlHost) -> String {
        var parts: [String] = []
        if host.state != "online" { parts.append(host.state.capitalized) }
        if !host.platform.isEmpty { parts.append(host.platform.replacingOccurrences(of: " ", with: " · ")) }
        if !host.version.isEmpty { parts.append("Agents \(host.version)") }
        parts.append(host.reach == "ssh" ? "reached over ssh" : "connects out")
        return parts.joined(separator: " · ")
    }
}

// MARK: - F · Clients

struct ControlClientsPage: View {
    @Environment(AppModel.self) private var model
    let control: ControlSettingsModel
    @State private var forgettingClient: ClientRecord?
    @State private var forgettingDevice: Device?
    @State private var pairingDevice = false
    @State private var pairingMac = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ControlCard {
                ForEach(Array(control.clients.enumerated()), id: \.element.id) { index, client in
                    if index > 0 { Divider() }
                    clientRow(client)
                }
                // Phones paired today still reach this Mac's host straight through the
                // bridge; they move onto the control plane with US4, and get a grant then.
                ForEach(model.devices) { device in
                    Divider()
                    ControlRow(dot: .none, title: device.name, detail: deviceLine(device)) {
                        HStack(spacing: 8) {
                            grantPicker(.device) { _ in }.disabled(true)
                            Button("Forget…") { forgettingDevice = device }.buttonStyle(.paper)
                        }
                    }
                }
            }
            HStack(spacing: 8) {
                Button("Pair a Device…") { pairingDevice = true }.buttonStyle(.paper)
                Button("Pair a Mac…") { pairingMac = true }.buttonStyle(.paper)
            }
            Text("Forgetting cuts a client off at once, at home and away. To use it again, pair it again. A phone’s grant can be changed once phones connect through the control plane.")
                .appText(.supporting).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .task { await model.refreshDevices() }
        .sheet(isPresented: $pairingDevice) { PairDeviceSheet() }
        .sheet(isPresented: $pairingMac) { PairMacSheet().paperSheet() }
        .confirmationDialog(forgettingClient.map { "Forget \($0.name)?" } ?? "",
                            isPresented: Binding(get: { forgettingClient != nil }, set: { if !$0 { forgettingClient = nil } }),
                            titleVisibility: .visible, presenting: forgettingClient) { client in
            Button("Forget", role: .destructive) { Task { await control.forget(client.id) } }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("It is cut off at once, at home and away, until it is paired again.")
        }
        .confirmationDialog(forgettingDevice.map { "Forget \($0.name)?" } ?? "",
                            isPresented: Binding(get: { forgettingDevice != nil }, set: { if !$0 { forgettingDevice = nil } }),
                            titleVisibility: .visible, presenting: forgettingDevice) { device in
            Button("Forget", role: .destructive) { Task { await model.forgetDevice(device.id) } }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("It stops reaching this Mac, at home and away, until you pair it again.")
        }
    }

    private func clientRow(_ client: ClientRecord) -> some View {
        let isYou = client.id == control.status?.you
        return ControlRow(dot: .none, title: isYou ? "This window" : client.name, chip: isYou ? "you" : nil,
                          detail: clientLine(client, isYou: isYou)) {
            HStack(spacing: 8) {
                grantPicker(client.grant) { grant in
                    Task { await control.setGrant(grant, of: client.id) }
                }
                if !isYou {
                    Button("Forget…") { forgettingClient = client }.buttonStyle(.paper)
                }
            }
        }
    }

    private func grantPicker(_ grant: Grant, change: @escaping (Grant) -> Void) -> some View {
        Picker("Grant", selection: Binding(get: { grant }, set: { if $0 != grant { change($0) } })) {
            Text("Operator").tag(Grant.operator)
            Text("Device").tag(Grant.device)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }

    private func clientLine(_ client: ClientRecord, isYou: Bool) -> String {
        let kind = switch client.kind {
        case .mac: "Mac"
        case .iPhone: "iPhone"
        case .iPad: "iPad"
        case .unknown: "Device"
        }
        var parts = [kind, "paired \(client.paired.formatted(.relative(presentation: .named)))"]
        if isYou { parts.append("connected") }
        else if let seen = client.lastSeen { parts.append("seen \(seen.formatted(.relative(presentation: .named)))") }
        return parts.joined(separator: " · ")
    }

    private func deviceLine(_ device: Device) -> String {
        var parts = [device.kind == .iPad ? "iPad" : "iPhone", "paired to this Mac’s agents"]
        if let seen = device.lastSeenAt { parts.append("seen \(seen.formatted(.relative(presentation: .named)))") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - G · Pair a Mac

/// Frame G for a Mac: the grant first, then the code as text, since a Mac has no camera.
/// The code needs pairing over the network (T018–T023, T029), which comes next; until then
/// the sheet says so where the code would be.
struct PairMacSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var grant: Grant = .operator

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Pair a Mac").appText(.reading).fontWeight(.semibold)
            HStack {
                Text("It may")
                Spacer()
                Picker("It may", selection: $grant) {
                    Text("do everything (Operator)").tag(Grant.operator)
                    Text("what a phone can (Device)").tag(Grant.device)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            Divider()
            Text("Pairing another Mac needs the control plane to listen on the network, which comes next. For now a Mac joins by running its own control plane.")
                .appText(.supporting).tinted(.attention)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}
