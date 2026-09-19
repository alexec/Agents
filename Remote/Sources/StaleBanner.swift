import AgentsKitCore
import SwiftUI

/// One line at the top when the Mac has stopped answering.
///
/// Information, not an error. A Mac asleep in another room is the ordinary case, and
/// the remote's job is to say when it last heard rather than to look broken. What sits
/// under it is dimmed and marked stale, and nothing on those screens offers an action
/// while this is showing (FR-035).
struct StaleBanner: View {
    @Environment(RemoteModel.self) private var model

    var body: some View {
        if model.isStale {
            HStack(spacing: 8) {
                Image(systemName: "wifi.slash")
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
        guard let last = model.lastHeard else { return "Not connected to your Mac yet" }
        return "Last heard from your Mac \(last)"
    }
}

/// What a screen looks like while it cannot be trusted: still readable, plainly not
/// current, and not offering anything.
extension View {
    func markedStale(_ isStale: Bool) -> some View {
        disabled(isStale)
            .opacity(isStale ? 0.55 : 1)
            .animation(.default, value: isStale)
    }
}
