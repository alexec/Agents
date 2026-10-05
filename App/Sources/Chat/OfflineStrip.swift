import AgentsKitCore
import SwiftUI

/// Across the top of a chat whose server has gone (037, wireframes/mac-offline.svg).
///
/// What the chat shows is what the window last had. The server's agents carry on
/// regardless; the window is simply not hearing them until it is back, which it will
/// try again for by itself.
struct OfflineStrip: View {
    @Environment(AppModel.self) private var model
    let host: HostID

    var body: some View {
        // The control plane being away is the window's own strip, above everything.
        if model.hosts.isOffline(host), !model.controlPlaneAway, case .offline(let since) = model.hosts.state(host) {
            HStack(spacing: 10) {
                Circle().tinted(.attention).frame(width: 7, height: 7)
                Text(line(since: since.formatted(date: .omitted, time: .shortened)))
                    .appText(.supporting)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if host != .mac, let next = model.hosts.nextTry[host] {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let seconds = max(0, Int(next.timeIntervalSince(context.date).rounded(.up)))
                        Text(seconds > 0 ? "Next try in \(seconds) s" : "Trying…")
                            .appText(.fine).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                if host == .mac {
                    Button("Try Again") { model.tryMacHostAgain() }
                        .controlSize(.small)
                } else {
                    Button("Try now") { model.hosts.retryNow() }
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .paperWell(in: RoundedRectangle(cornerRadius: Paper.Radius.card))
            .chatColumn()
            .padding(.top, 8)
        }
    }

    /// In the same words as the Remote's strip (`OfflineWords`).
    private func line(since: String) -> String {
        OfflineWords.line(host: host, name: model.hosts.label(host), since: since)
    }
}
