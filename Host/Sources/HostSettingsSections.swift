import AgentsKitCore
import AppKit
import SwiftUI

/// Settings ▸ Machines ▸ This Mac, at the top (#4227): what was the Host window's This Mac
/// card. Whether the two login items run and why not, with Repair or Open Login Items; a
/// join that keeps failing, with Try Again; the diagnostics; and Remove Agents from This
/// Mac….
struct HostMacSection: View {
    let host: HostModel
    @State private var confirmingRemove = false

    var body: some View {
        Section {
            if host.removed {
                removedRows
            } else {
                LabeledContent {
                    Circle().frame(width: 8, height: 8).foregroundStyle(dot)
                } label: {
                    Text("Agents on this Mac")
                    Text(line)
                }
                // Why a login item isn't running, as launchd and macOS say it, for as long as
                // it holds (#678): never an endless Starting….
                if let reason = host.failureReason {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Label(reason, systemImage: "exclamationmark.triangle")
                            .tinted(.attention)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityLabel("Why it isn’t running: \(reason)")
                        Spacer(minLength: 8)
                        if host.canRepair {
                            Button("Repair") { Task { await host.repair() } }
                                .help("Registers both login items again from this copy of Agents and starts them.")
                        } else {
                            Button("Open Login Items") { HostSettingsLinks.openLoginItems() }
                        }
                    }
                    .disabled(host.busy != nil)
                }
                // The host's own word on its join, while it keeps failing (#113).
                if host.hostJoinFailed, let join = host.hostJoin {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(join.summary).tinted(.attention).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Button("Try Again") { Task { await host.retryJoin() } }
                            .disabled(host.busy != nil)
                    }
                }
                if let note = host.mustJoinNote {
                    Label(note, systemImage: OrgPolicyWords.symbol)
                        .tinted(.attention).fixedSize(horizontal: false, vertical: true)
                }
                HostOutcome(host: host)
                // What to send with a bug report, and where the logs are (#678); also in Help.
                HStack(spacing: 14) {
                    Button("Copy Diagnostics") { Task { await host.copyDiagnostics() } }
                        .help("Copies a report with secrets left out: this copy, both login items, what listens, and the end of both logs.")
                    Button("Save Diagnostics…") { Task { await host.saveDiagnostics() } }
                    Button("Show Logs") { host.showLogs() }
                    Spacer()
                }
                .buttonStyle(.link)
                .disabled(host.busy != nil)
                HStack {
                    Button("Remove Agents from This Mac…", role: .destructive) { confirmingRemove = true }
                    Spacer()
                }
                .disabled(host.busy != nil)
            }
        } header: {
            Text("Agents")
        } footer: {
            if !host.removed {
                Text("Your agents run in two login items, the control plane and this Mac’s machine, which keep running with the window closed. Remove Agents from This Mac stops them before you move Agents to the Trash.")
                    .appText(.fine)
                    .foregroundStyle(.secondary)
            }
        }
        .paperListRow()
        .confirmationDialog("Remove Agents from this Mac?", isPresented: $confirmingRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { Task { await host.removeFromThisMac() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every agent on this Mac stops, and both login items go. Windows, phones and browsers can’t reach this Mac until you open Agents again. Your sessions and folders are kept.")
        }
        .hostLooking(host)
    }

    @ViewBuilder
    private var removedRows: some View {
        Label("Agents is removed from this Mac’s login items. Quit Agents, then move it to the Trash.", systemImage: "checkmark.circle")
            .fixedSize(horizontal: false, vertical: true)
        Text("Your sessions are kept in \(host.paths.hostRoot.path) and the control plane’s records in \(host.paths.controlHome.path). Delete those folders too to remove them. Opening Agents again sets it up afresh.")
            .appText(.supporting).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        HStack {
            Spacer()
            Button("Show Agents in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }
            Button("Quit Agents") { NSApp.terminate(nil) }
                .keyboardShortcut(.defaultAction)
        }
    }

    /// Grey when the process is down, orange when it is up and has no membership (#303),
    /// red when it can't start (#678).
    private var dot: Color {
        if host.daemonFailure != nil { return .red }
        guard host.daemonRunning else { return Color.secondary.opacity(0.4) }
        if host.hostJoin?.member == false { return .orange }
        return .green
    }

    /// Its version is under Updates.
    private var line: String {
        guard host.daemonRunning else {
            if host.settings.role == .none { return "Not set up" }
            return host.daemonFailure != nil ? "Not running" : "Starting…"
        }
        if host.hostJoin?.member == false { return "Running, and not joined to the control plane" }
        var parts = ["Running your agents"]
        if let working = host.working { parts.append("\(working) working") }
        if let folders = host.folders { parts.append(count(folders, "folder")) }
        return parts.joined(separator: " · ")
    }
}

/// Settings ▸ Control plane ▸ Overview, under the control plane's own card (#4227): what
/// was the Host window's CONTROL PLANE card: moving the control plane to another machine
/// and back. Its store is always on this Mac (#4227): a cloud one is a control plane run
/// there, not this Mac's in a bucket.
struct HostControlPlaneCards: View {
    let host: HostModel
    @State private var movingMachine = false
    @State private var returning = false
    @State private var confirmingStop = false
    @State private var confirmingReturnStop = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if host.settings.role == .runHere {
                ControlCard {
                    ControlRow(dot: .none, title: "Move to Another Machine",
                               detail: "To a server you run, with every machine, window and phone kept. This Mac forwards them there for a while.") {
                        // Frame O: the control plane moved off this Mac, everyone kept (T126).
                        Button("Move…") { movingMachine = true }
                            .buttonStyle(.paper)
                            .disabled(!host.controlRunning || host.busy != nil)
                    }
                    if let place = host.settings.returnedFrom {
                        Divider()
                        returnRow(place)
                    }
                }
            } else if host.settings.role == .joinElsewhere, let place = host.settings.movedTo {
                // Joined by a code is Use This Mac Only's, beside the control plane's row (#4228).
                movedCard(place)
            }
            HostOutcome(host: host)
        }
        .sheet(isPresented: $movingMachine) { MachineMoveSheet().environment(host) }
        .sheet(isPresented: $returning) { MachineReturnSheet().environment(host) }
        .confirmationDialog("Stop forwarding?", isPresented: $confirmingStop) {
            Button("Stop Forwarding", role: .destructive) { Task { await host.stopForwarding() } }
        } message: {
            Text(Self.stopMessage(host.forwarding))
        }
        .confirmationDialog("Stop forwarding?", isPresented: $confirmingReturnStop) {
            Button("Stop Forwarding", role: .destructive) { Task { await host.stopReturnForwarding() } }
        } message: {
            Text(Self.stopMessage(host.returnForwarding))
        }
        .hostLooking(host)
    }

    // MARK: Joined elsewhere (frame T)

    private func movedCard(_ place: String) -> some View {
        ControlCard {
            ControlRow(dot: host.daemonRunning ? .online : .attention, title: "This Mac moved its control plane",
                       detail: movedLine(place)) {
                // Frame U: the way back (T127).
                Button("Run It Here Again…") { returning = true }
                    .buttonStyle(.paper).disabled(host.busy != nil)
            }
            if let until = host.settings.forwardingUntil {
                Divider()
                ControlRow(dot: .attention, title: "Forwarding from \(host.controlURL)",
                           detail: Self.forwardingLine(until, host.forwarding)) {
                    Button("Stop Forwarding…") { confirmingStop = true }.buttonStyle(.paper)
                }
            }
        }
    }

    private func movedLine(_ place: String) -> String {
        var parts = ["Joined \(place)"]
        if let at = host.settings.movedAt { parts.append("moved \(at.formatted(date: .omitted, time: .shortened))") }
        parts.append("this Mac is a machine there")
        return parts.joined(separator: " · ")
    }

    // MARK: Came back (frame Y)

    private func returnRow(_ place: String) -> some View {
        let name = URL(string: place)?.host ?? place
        let until = host.settings.returnForwardingUntil.map { " until \($0.formatted(date: .long, time: .omitted))" } ?? ""
        return ControlRow(dot: host.returnForwardingDone ? .online : .attention,
                          title: host.returnForwardingDone ? "Everyone has heard. You can take \(name) down." : "\(name) forwards here\(until)",
                          detail: host.returnForwardingDone ? "" : returnLine) {
            if host.returnForwardingDone {
                Button("Dismiss") { host.dismissReturn() }.buttonStyle(.paper)
            } else {
                Button("Stop Forwarding…") { confirmingReturnStop = true }.buttonStyle(.paper)
            }
        }
    }

    private var returnLine: String {
        guard let left = host.returnForwarding?.stillToHear, !left.isEmpty else { return "Then you can take that machine down." }
        return "\(left.count) still to hear: \(Self.names(left)). Then you can take that machine down."
    }

    private static func forwardingLine(_ until: Date, _ status: HandoverStatus?) -> String {
        let date = "until \(until.formatted(date: .long, time: .omitted))"
        guard let status else { return date }
        guard !status.stillToHear.isEmpty else { return "\(date) · everyone has heard" }
        return "\(date) · \(status.stillToHear.count) still to hear: \(names(status.stillToHear))"
    }

    private static func names(_ left: [HandoverStatus.Member]) -> String {
        left.map { member in
            var said = member.id == MachineRef.mac.rawValue ? "This Mac" : member.name
            if member.online != true, let seen = member.lastSeen {
                said += ", last connected \(seen.formatted(.relative(presentation: .named)))"
            }
            return said
        }
        .joined(separator: "; ")
    }

    private static func stopMessage(_ status: HandoverStatus?) -> String {
        let left = status?.stillToHear.map(\.name) ?? []
        guard !left.isEmpty else { return "Everyone has heard where the control plane went." }
        return "\(ListFormatter.localizedString(byJoining: left)) will need pairing again."
    }
}

/// Serve Agents to browsers on this Mac (071 FR-002), under the browser card in Settings ▸
/// Control plane ▸ Overview (#4227): on unless turned off, and only ever on loopback. With
/// the control plane elsewhere, this Mac's host serves it (#1952). Its line says what the
/// control plane says: never the address of a page it isn't serving (071 R3).
struct HostServeCard: View {
    let host: HostModel

    var body: some View {
        if host.settings.role != .none {
            ControlCard {
                ControlRow(dot: host.webRemoteFailed ? .attention : .none,
                           title: "Serve Agents to browsers on this Mac", detail: host.webRemoteLine) {
                    if host.webRemoteFailed {
                        Button("Try Again") { Task { await host.retryWebRemote() } }.buttonStyle(.paper)
                    }
                    Toggle("Serve Agents to browsers on this Mac",
                           isOn: Binding(get: { host.settings.servesWebRemote },
                                         set: { on in Task { await host.setServeWebRemote(on) } }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
            }
            .disabled(host.busy != nil)
        }
    }
}

/// What a step of the host's came to: a step under way, what went wrong, or what Repair or
/// Copy Diagnostics did.
private struct HostOutcome: View {
    let host: HostModel

    var body: some View {
        if let busy = host.busy {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(busy).foregroundStyle(.secondary)
            }
        } else if let problem = host.problem {
            Label(problem, systemImage: "exclamationmark.triangle")
                .tinted(.failure).fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("Problem: \(problem)")
        } else if let repaired = host.repaired, host.failureReason == nil {
            Label(repaired, systemImage: "checkmark.circle")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

enum HostSettingsLinks {
    /// System Settings ▸ General ▸ Login Items.
    @MainActor static func openLoginItems() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
    }
}

extension View {
    /// The host's loop while this view is on screen (#134): out of sight it looks at nothing;
    /// in sight, mostly without starting a process.
    func hostLooking(_ host: HostModel) -> some View { modifier(HostLooking(host: host)) }
}

private struct HostLooking: ViewModifier {
    let host: HostModel
    @State private var window: NSWindow?

    func body(content: Content) -> some View {
        content
            .background(WindowReader(window: $window))
            .task {
                while !Task.isCancelled {
                    // Before the window is known, as if seen and key: the first look is a full one.
                    let visible = !NSApp.isHidden && (window?.occlusionState.contains(.visible) ?? true)
                    await host.tick(visible: visible, key: window?.isKeyWindow ?? true)
                    try? await Task.sleep(for: HostRefreshPolicy.tick)
                }
            }
    }
}

/// The window a view is in, for whether it can be seen and is key.
private struct WindowReader: NSViewRepresentable {
    @Binding var window: NSWindow?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { window = view.window }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        if view.window !== window { DispatchQueue.main.async { window = view.window } }
    }
}
