import AgentsKitCore
import SwiftUI

/// The host's strip (#5034, first of the session's strips; #239), as the window's
/// `OfflineStrip`: which host, and since when, with a grey glyph. The Mac's own link is
/// `StaleBanner`'s, so this says nothing for an agent on the Mac.
///
/// What is under it is what the phone last had, and greyed. The server's agents carry
/// on regardless; the phone dials it again by itself, so there is nothing to press,
/// unless the host runs on a provider's workspace (#691, layouts.md L1): then a stopped
/// or failed one offers Start, and a starting one shows a spinner and how long so far.
struct HostOfflineStrip: View {
    @Environment(RemoteModel.self) private var model
    let host: MachineRef

    @MainActor
    static func isShown(_ host: MachineRef, model: RemoteModel) -> Bool {
        host != .mac && model.isStale(on: host)
    }

    var body: some View {
        if Self.isShown(host, model: model) {
            let name = model.hostName(host)
            let row = model.controlHost(host)
            let workspace = row?.workspace
            let state = row?.state ?? "offline"
            let line = workspace.flatMap { OfflineWords.workspaceLine(name: name, state: state, workspace: $0) }
                ?? OfflineWords.line(host: host, name: name,
                                     since: model.hostDownSince[host]?.formatted(date: .omitted, time: .shortened))
            let starting = workspace != nil && state == "starting"
            let start = workspace.map { OfflineWords.offersStart(state: state, workspace: $0) } ?? false
            Strip(tone: .neutral, symbol: MessageTone.offlineSymbol, busy: starting, line: line,
                  primary: start ? StripButton(title: "Start", disabled: model.hostsBeingStarted.contains(host)) {
                      Task { await model.startHost(host) }
                  } : nil) {
                if starting, let since = workspace?.since {
                    TimelineView(.periodic(from: since, by: 1)) { context in
                        Text(OfflineWords.elapsed(since: since, now: context.date))
                            .appText(.fine)
                            .monospacedDigit()
                            .foregroundStyle(Paper.secondary)
                    }
                }
            }
        }
    }
}
