import AgentsKit
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
        if model.hosts.isOffline(host), case .offline(let since) = model.hosts.state(host) {
            HStack(spacing: 10) {
                Circle().fill(.gray).frame(width: 7, height: 7)
                Text("\(model.hosts.label(host)) is offline since \(since.formatted(date: .omitted, time: .shortened)). Agents there keep working.")
                    .appText(.supporting)
                Spacer(minLength: 8)
                if let next = model.hosts.nextTry[host] {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let seconds = max(0, Int(next.timeIntervalSince(context.date).rounded(.up)))
                        Text(seconds > 0 ? "Next try in \(seconds) s" : "Trying…")
                            .appText(.fine).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                Button("Try now") { model.hosts.retryNow() }
                    .controlSize(.small)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
            .chatColumn()
            .padding(.top, 8)
        }
    }
}
