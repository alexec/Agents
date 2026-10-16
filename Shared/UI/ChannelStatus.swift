import AgentsKitCore
import SwiftUI

/// A channel's row on Settings ▸ Channels (#1109): its dot and its status line, the same on
/// the window and the Remote. Slack (#1009) is the first channel; the next one adds a case.
enum ChannelStatus: Equatable {
    case connected
    case notConnected
    case notAvailable

    init(_ slack: DaemonAPI.SlackState) {
        if !slack.available { self = .notAvailable }
        else if slack.status == DaemonAPI.SlackState.connected { self = .connected }
        else { self = .notConnected }
    }

    var line: String {
        switch self {
        case .connected: "Connected"
        case .notConnected: "Not connected"
        case .notAvailable: "Not available"
        }
    }

    /// Green when connected; the surface's own grey otherwise.
    var tint: StateTint { self == .connected ? .vouched : .none }
}

/// A channel's dot, in its status's tint, or in `.tertiary` with none.
struct ChannelDot: View {
    let status: ChannelStatus

    var body: some View {
        Circle()
            .fill(status.tint.style(or: .tertiary))
            .frame(width: 8, height: 8)
            .accessibilityHidden(true)
    }
}
