import AgentsKitCore
import SwiftUI

/// Across the top of a chat or the start sheet whose server has gone (#239), as the
/// window's `OfflineStrip`: which host, and since when. The Mac's own link is
/// `StaleBanner`'s, so this says nothing for an agent on the Mac.
///
/// What is under it is what the phone last had, and greyed. The server's agents carry
/// on regardless; the phone dials it again by itself, so there is nothing to press.
struct HostOfflineStrip: View {
    @Environment(RemoteModel.self) private var model
    let host: HostID

    var body: some View {
        if host != .mac, model.isStale(on: host) {
            let line = OfflineWords.line(host: host, name: model.hostName(host),
                                         since: model.hostDownSince[host]?.formatted(date: .omitted, time: .shortened))
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle().tinted(.attention)
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
                Text(line)
                    .appText(.fine)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(Paper.wash)
            // One element, as the banner's rows are (the stacked-labels memory).
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(line)
        }
    }
}
