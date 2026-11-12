import AgentsKitCore
import SwiftUI

/// Across the top of the window when the control plane cannot be reached (058, frame H): a
/// banner (#4737), neutral, or attention when the address refused and Open Account shows.
///
/// Every host's folders stay listed under it, greyed. Agents keep working on their
/// hosts; the window catches up when the control plane is back.
struct ControlAwayStrip: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL

    var body: some View {
        let line = model.controlPlaneAwayLine ?? "Can’t reach the control plane. Your agents are still working."
        // A hosted account's refusal names its account page (#3153): one click to it.
        let account = model.controlPlaneAwayLine.flatMap(ControlRefusal.link(in:))
        PaneBanner(tone: account == nil ? .neutral : .attention,
                   symbol: account == nil ? MessageTone.offlineSymbol : nil, line) {
            if let account {
                Button("Open Account") { openURL(account) }
            }
            Button("Try Again") { model.tryControlPlaneAgain() }
        }
        .paneBannerInset()
    }
}
