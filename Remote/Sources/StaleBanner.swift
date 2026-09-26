import AgentsKitCore
import SwiftUI
import UIKit

/// One line at the top when the Mac has stopped answering.
///
/// Information, not an error. A Mac asleep in another room is the ordinary case, and
/// the remote's job is to say when it last heard rather than to look broken. What sits
/// under it is dimmed and marked stale, and nothing on those screens offers an action
/// while this is showing (FR-035).
struct StaleBanner: View {
    @Environment(RemoteModel.self) private var model

    var body: some View {
        if model.needsPairingAtHome {
            // Never paired, or forgotten by the Mac (046): the list below may still be what
            // it last knew, so the one thing to do is said here, on every screen.
            row(icon: "house", lead: nil, line: "Open Agents once on your Mac's Wi-Fi to reach it from anywhere")
        } else if model.isStale {
            row(icon: "wifi.slash", lead: nil, line: staleLine)
        } else if let trouble = troubleLine {
            row(icon: "icloud.slash", lead: nil, line: trouble)
        } else if model.isAway {
            // Away (046, look A): not a fault, and said as the reason things are slower.
            row(icon: "icloud", lead: "Away",
                line: model.relayTrouble.map { if case .slowedDown = $0 { true } else { false } } == true
                    ? "slower than usual" : "slower, through iCloud")
        }
    }

    private func row(icon: String, lead: String?, line: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .appText(.fine)
                .accessibilityHidden(true)
            if let lead {
                (Text(lead).foregroundStyle(.primary).fontWeight(.semibold) + Text(" — \(line)"))
                    .appText(.fine)
            } else {
                Text(line)
                    .appText(.fine)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(Paper.ground)
        // One element for the row, with nothing below it labelled (the stacked-labels
        // memory): the words are the whole of it.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(lead.map { "\($0), \(line)" } ?? line)
    }

    private var staleLine: String {
        guard let last = model.lastHeard else { return "Not connected to your Mac yet" }
        return "Last heard from your Mac \(last)"
    }

    private var troubleLine: String? {
        switch model.relayTrouble {
        case .noICloud?: "The relay needs iCloud on your \(device) and your Mac"
        case .iCloudFull?: "iCloud is full, so the relay can't carry messages"
        default: nil
        }
    }

    private var device: String { UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone" }
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
