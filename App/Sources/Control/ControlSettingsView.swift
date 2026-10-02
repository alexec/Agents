import AgentsKitCore
import AppKit
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
                    Text("Can’t reach the control plane at \(control.whereItIs). What it last said is shown.")
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
                // What the control plane says of its web remote, never just the address (071 R3).
                if let web = control.status?.web {
                    Divider()
                    ControlRow(dot: web.served ? .none : .attention, title: "Browsers on this Mac",
                               detail: web.served ? web.summary : "\(web.summary) Try again in Agents Host.") {
                        Text(web.served ? "On" : "Not serving")
                            .appText(.reading)
                            .foregroundStyle(.secondary)
                    }
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
                           title: count(control.clients.count, "client"),
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
        let name = host.machineID == MachineID.current && host.relay != true ? "This Mac" : host.name
        return host.state == "online" ? name : "\(name) (\(host.state))"
    }
}

func count(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }

// MARK: - E · Hosts

struct ControlHostsPage: View {
    @Environment(AppModel.self) private var model
    let control: ControlSettingsModel
    @State private var removing: DaemonAPI.ControlHost?
    @State private var addingByCode = false
    @State private var addingServer = false

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
                Button("Add a Server…") { addingServer = true }.buttonStyle(.paper)
                Button("Add by Code…") { addingByCode = true }.buttonStyle(.paper)
            }
            Text("Add a Server gives you one command to run on it, or installs it over ssh with a key you give once. Either way the server connects out, so nothing has to reach it. Add by Code gives another Mac a code to join with. Removing a host stops it connecting. Its agents are left running where they are.")
                .appText(.supporting).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .sheet(isPresented: $addingByCode) { CodeSheet(control: control, purpose: .host).paperSheet() }
        .sheet(isPresented: $addingServer) { ControlAddServerSheet(control: control).paperSheet() }
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
        // agents-relay (T096): it runs no agents, so the rest of the line is not its.
        if host.relay != nil {
            let state = host.state == "online" ? "" : "\(host.state.capitalized) · "
            return state + (host.relay == true ? "Relays your devices through iCloud" : "Relaying switched off")
        }
        var parts: [String] = []
        if host.state != "online" { parts.append(host.state.capitalized) }
        if !host.platform.isEmpty { parts.append(host.platform.replacingOccurrences(of: " ", with: " · ")) }
        if !host.version.isEmpty { parts.append("Agents \(host.version)") }
        parts.append("connects out")
        // The sign-in relay needs a path back to this Mac, which the control plane does
        // not carry yet (R9). A lent key still works; the relay does not.
        parts.append("Sign-in relay needs this Mac on the same network")
        return parts.joined(separator: " · ")
    }
}

// MARK: - G · Pair a Mac, and Add by Code

/// Frame G: the code as text, since a Mac has no camera; and the same sheet for a host's
/// code. Every client may do everything (#111), so there is nothing to choose first.
struct CodeSheet: View {
    /// A browser is a client like a Mac, on this Mac only (071, frame E).
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
        case .browser: "Pair a Browser"
        case .host: "Add a host by code"
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
            return "Paste it into Agents in a browser on this Mac, at localhost. That browser can then do all this window can. \(time)"
        case .host:
            return "On the other machine, start its agents with agentsd --control-code and this code. \(time)"
        }
    }
}
