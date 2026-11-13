import AgentsKitCore
import SwiftUI

/// Across the top of a chat or the start sheet whose server has gone (#239), as the
/// window's `OfflineStrip`, a neutral banner (#4737): which host, and since when. The Mac's own link is
/// `StaleBanner`'s, so this says nothing for an agent on the Mac.
///
/// What is under it is what the phone last had, and greyed. The server's agents carry
/// on regardless; the phone dials it again by itself, so there is nothing to press,
/// unless the host runs on a provider's workspace (#691, layouts.md L1): then a stopped
/// or failed one offers Start, and a starting one shows a spinner and how long so far.
struct HostOfflineStrip: View {
    @Environment(RemoteModel.self) private var model
    let host: MachineRef

    var body: some View {
        if host != .mac, model.isStale(on: host) {
            let name = model.hostName(host)
            let row = model.controlHost(host)
            let workspace = row?.workspace
            let state = row?.state ?? "offline"
            let line = workspace.flatMap { OfflineWords.workspaceLine(name: name, state: state, workspace: $0) }
                ?? OfflineWords.line(host: host, name: name,
                                     since: model.hostDownSince[host]?.formatted(date: .omitted, time: .shortened))
            let starting = workspace != nil && state == "starting"
            // Neutral (#4737): the phone dials again by itself.
            PaneBanner(tone: .neutral, symbol: MessageTone.offlineSymbol, busy: starting, announcement: line) {
                Text(line)
            } actions: {
                if starting, let since = workspace?.since {
                    TimelineView(.periodic(from: since, by: 1)) { context in
                        Text(OfflineWords.elapsed(since: since, now: context.date))
                            .appText(.fine)
                            .monospacedDigit()
                            .foregroundStyle(Paper.secondary)
                    }
                } else if let workspace, OfflineWords.offersStart(state: state, workspace: workspace) {
                    Button("Start") {
                        Task { await model.startHost(host) }
                    }
                    .disabled(model.hostsBeingStarted.contains(host))
                    .accessibilityLabel("Start \(name)")
                }
            }
            .paneBannerInset()
            .remoteBannerGround()
        }
    }
}
