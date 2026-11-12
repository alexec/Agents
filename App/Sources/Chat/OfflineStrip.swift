import AgentsKitCore
import SwiftUI

/// Across the top of a chat whose server has gone (037, wireframes/mac-offline.svg): a
/// neutral banner (#4737).
///
/// What the chat shows is what the window last had. A server's agents carry on; the
/// window tries that host again by itself. This Mac's host says whether it is down,
/// not enrolled, or quiet after it had joined (#303).
struct OfflineStrip: View {
    @Environment(AppModel.self) private var model
    let host: MachineRef

    var body: some View {
        // The control plane being away is the window's own strip, above everything.
        if let text = line {
            // Neutral (#4737): the person need not act; the window tries again by itself.
            PaneBanner(tone: .neutral, symbol: MessageTone.offlineSymbol, busy: starting,
                       announcement: text) {
                Text(text)
            } actions: {
                if let workspace, starting, let since = workspace.since {
                    // How long the start has taken so far (#691, L1).
                    TimelineView(.periodic(from: since, by: 1)) { context in
                        Text(OfflineWords.elapsed(since: since, now: context.date))
                            .appText(.fine).foregroundStyle(.secondary).monospacedDigit()
                    }
                } else if let workspace, OfflineWords.offersStart(state: row?.state ?? "offline", workspace: workspace) {
                    Button("Start") { Task { await model.startHost(host) } }
                        .disabled(model.hostsBeingStarted.contains(host))
                        .help("Starts \(workspace.workspaceName) at \(workspace.providerName).")
                } else if starting || workspace?.hostState == "stopping" {
                    EmptyView()
                } else if host != .mac, let next = model.hosts.nextTry[host] {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let seconds = max(0, Int(next.timeIntervalSince(context.date).rounded(.up)))
                        Text(seconds > 0 ? "Next try in \(seconds) s" : "Trying…")
                            .appText(.fine).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                if host == .mac {
                    Button("Try Again") { model.tryMacHostAgain() }
                } else {
                    Button("Try now") { model.hosts.retryNow() }
                }
            }
            .chatColumn()
            .padding(.top, 8)
        }
    }

    /// This Mac's host names why it is quiet (#303). A server's strip stays the shared
    /// words, which the Remote uses too: for one on a provider's workspace, whether it is
    /// stopped, starting or failed to start (#691).
    private var line: String? {
        guard !model.controlPlaneAway else { return nil }
        if host == .mac, let notice = model.macHostNotice {
            return notice.strip(since: offlineSince)
        }
        guard model.hosts.isOffline(host), case .offline(let since) = model.hosts.state(host) else { return nil }
        if let row, let workspace,
           let words = OfflineWords.workspaceLine(name: model.hosts.label(host), state: row.state, workspace: workspace) {
            return words
        }
        return OfflineWords.line(host: host, name: model.hosts.label(host),
                                 since: since.formatted(date: .omitted, time: .shortened))
    }

    private var row: DaemonAPI.ControlMachine? { host == .mac ? nil : model.hosts.controlRows[host] }
    private var workspace: DaemonAPI.MachineWorkspace? { row?.workspace }
    private var starting: Bool { workspace != nil && row?.state == "starting" }

    private var offlineSince: String? {
        guard case .offline(let since) = model.hosts.state(host) else { return nil }
        return since.formatted(date: .omitted, time: .shortened)
    }
}
