import AgentsKitCore
import SwiftUI

/// Across the top of the window when the control plane cannot be reached (058, frame H): a
/// strip (#5034), grey, or orange when the address refused and Open Account shows. Above every
/// page, not one session's, so it is the window's and not in a chat's stack.
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
        Strip(tone: account == nil ? .neutral : .warning,
              symbol: account == nil ? MessageTone.offlineSymbol : nil, line: line,
              primary: StripButton(title: "Try Again") { model.tryControlPlaneAgain() },
              second: account.map { url in StripButton(title: "Open Account") { openURL(url) } })
            .paneBannerInset()
    }
}
