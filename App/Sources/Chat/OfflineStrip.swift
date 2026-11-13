import AgentsKitCore
import SwiftUI

/// The host's strip (#5034, first of the session's strips; 037, wireframes/mac-offline.svg):
/// the session's host has gone. A grey glyph: the window tries that host again by itself.
///
/// What the chat shows is what the window last had. A server's agents carry on; the
/// window tries that host again by itself. This Mac's host says whether it is down,
/// not enrolled, or quiet after it had joined (#303).
struct OfflineStrip: View {
    @Environment(AppModel.self) private var model
    let host: MachineRef

    /// Whether `host` has a strip now. The control plane being away is the window's own
    /// strip, above everything.
    @MainActor
    static func isShown(_ host: MachineRef, model: AppModel) -> Bool {
        line(host, model: model) != nil
    }

    var body: some View {
        if let text = Self.line(host, model: model) {
            Strip(tone: .neutral, symbol: MessageTone.offlineSymbol, busy: starting, line: text,
                  primary: primary, second: second) {
                if let workspace, starting, let since = workspace.since {
                    // How long the start has taken so far (#691, L1).
                    TimelineView(.periodic(from: since, by: 1)) { context in
                        Text(OfflineWords.elapsed(since: since, now: context.date))
                            .appText(.fine).foregroundStyle(.secondary).monospacedDigit()
                    }
                } else if host != .mac, !offersStart, !starting, workspace?.hostState != "stopping",
                          let next = model.hosts.nextTry[host] {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let seconds = max(0, Int(next.timeIntervalSince(context.date).rounded(.up)))
                        Text(seconds > 0 ? "Next try in \(seconds) s" : "Trying…")
                            .appText(.fine).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }
        }
    }

    /// Start, for a stopped workspace; else the try.
    private var primary: StripButton {
        if let workspace, offersStart {
            return StripButton(title: "Start", help: "Starts \(workspace.workspaceName) at \(workspace.providerName).",
                               disabled: model.hostsBeingStarted.contains(host)) {
                Task { await model.startHost(host) }
            }
        }
        return tryButton
    }

    /// The try, beside Start.
    private var second: StripButton? { offersStart ? tryButton : nil }

    private var tryButton: StripButton {
        host == .mac
            ? StripButton(title: "Try Again") { model.tryMacHostAgain() }
            : StripButton(title: "Try now") { model.hosts.retryNow() }
    }

    private var offersStart: Bool {
        guard let workspace else { return false }
        return OfflineWords.offersStart(state: row?.state ?? "offline", workspace: workspace)
    }

    /// This Mac's host names why it is quiet (#303). A server's strip stays the shared
    /// words, which the Remote uses too: for one on a provider's workspace, whether it is
    /// stopped, starting or failed to start (#691).
    @MainActor
    private static func line(_ host: MachineRef, model: AppModel) -> String? {
        guard !model.controlPlaneAway else { return nil }
        let offlineSince: String? = {
            guard case .offline(let since) = model.hosts.state(host) else { return nil }
            return since.formatted(date: .omitted, time: .shortened)
        }()
        if host == .mac, let notice = model.macHostNotice {
            return notice.strip(since: offlineSince)
        }
        guard model.hosts.isOffline(host), case .offline(let since) = model.hosts.state(host) else { return nil }
        let row = host == .mac ? nil : model.hosts.controlRows[host]
        if let row, let workspace = row.workspace,
           let words = OfflineWords.workspaceLine(name: model.hosts.label(host), state: row.state, workspace: workspace) {
            return words
        }
        return OfflineWords.line(host: host, name: model.hosts.label(host),
                                 since: since.formatted(date: .omitted, time: .shortened))
    }

    private var row: DaemonAPI.ControlMachine? { host == .mac ? nil : model.hosts.controlRows[host] }
    private var workspace: DaemonAPI.MachineWorkspace? { row?.workspace }
    private var starting: Bool { workspace != nil && row?.state == "starting" }
}
