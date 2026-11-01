import AgentsKitCore
import SwiftUI

/// Across the top of the window when the control plane cannot be reached (058, frame H).
///
/// Every host's folders stay listed under it, greyed. Agents keep working on their
/// hosts; the window catches up when the control plane is back.
struct ControlAwayStrip: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL

    var body: some View {
        HStack {
            Text(model.controlPlaneAwayLine ?? "Can’t reach the control plane. Your agents are still working.")
                .appText(.supporting)
            Spacer()
            // A hosted account's refusal names its account page (#3153): one click to it.
            if let line = model.controlPlaneAwayLine, let account = ControlRefusal.link(in: line) {
                Button("Open Account") { openURL(account) }
                    .buttonStyle(.paper)
            }
            Button("Try Again") { model.tryControlPlaneAgain() }
                .buttonStyle(.paper)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Paper.wash)
    }
}
