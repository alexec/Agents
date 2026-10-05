import AgentsKitCore
import SwiftUI

/// Across the top of a chat whose server has gone (037, wireframes/mac-offline.svg).
///
/// What the chat shows is what the window last had. A server's agents carry on; the
/// window tries that host again by itself. This Mac's host says whether it is down,
/// not enrolled, or quiet after it had joined (#303).
struct OfflineStrip: View {
    @Environment(AppModel.self) private var model
    let host: HostID

    var body: some View {
        // The control plane being away is the window's own strip, above everything.
        if let text = line {
            HStack(spacing: 10) {
                Circle().tinted(.attention).frame(width: 7, height: 7)
                Text(text)
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

    /// This Mac's host names why it is quiet (#303). A server's strip stays the shared
    /// words, which the Remote uses too.
    private var line: String? {
        guard !model.controlPlaneAway else { return nil }
        if host == .mac, let notice = model.macHostNotice {
            return notice.strip(since: offlineSince)
        }
        guard model.hosts.isOffline(host), case .offline(let since) = model.hosts.state(host) else { return nil }
        return OfflineWords.line(host: host, name: model.hosts.label(host),
                                 since: since.formatted(date: .omitted, time: .shortened))
    }

    private var offlineSince: String? {
        guard case .offline(let since) = model.hosts.state(host) else { return nil }
        return since.formatted(date: .omitted, time: .shortened)
    }
}
