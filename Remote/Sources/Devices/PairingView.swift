import AgentsKitCore
import SwiftUI

/// One line at the top until the Mac has approved this device.
///
/// Announcing happens by itself on every connection; the only thing left for the person
/// is to say yes at the Mac, and this says so plainly rather than leaving the device
/// looking paired while it is told nothing (021 US5). It goes when the Mac approves,
/// and comes back if the Mac revokes.
struct PairingView: View {
    @Environment(RemoteModel.self) private var model

    var body: some View {
        if model.isConnected, !model.isPaired {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "lock.open.iphone")
                    .font(.footnote)
                    .accessibilityHidden(true)
                Text(line)
                    .font(.footnote)
                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(.bar)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(line)
        }
    }

    private var line: String {
        if let problem = model.pairingProblem { return problem }
        guard model.thisDevice != nil else { return "Asking your Mac to pair with this device…" }
        return "Waiting for you to approve this device on your Mac, in Agents › Settings › Devices. "
            + "Until then it will not be told when an agent needs you."
    }
}
