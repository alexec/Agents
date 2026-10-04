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
        VStack(spacing: 0) {
            connection
            // While it can be trusted: a stale banner says nothing here is current.
            if !model.isStale && !model.needsPairing { DiskRows() }
        }
    }

    @ViewBuilder private var connection: some View {
        if model.needsPairing {
            // Never paired, or forgotten by the Mac: the list below may still be what it
            // last knew, so the one thing to do is said here, on every screen.
            row(icon: "qrcode.viewfinder", lead: nil, line: "Scan the code on your Mac to connect")
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
                Text("\(Text(lead).foregroundStyle(.primary).fontWeight(.semibold)) — \(line)")
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

/// A volume on the Mac low on space (#196), as the window's DiskStrip (#195): how much is
/// free, and the largest worktrees when they could be measured. Gone by itself once it
/// climbs back.
private struct DiskRows: View {
    @Environment(RemoteModel.self) private var model

    var body: some View {
        ForEach(model.work.disk.alarms) { alarm in
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle().tinted(alarm.level == .critical ? .failure : .attention)
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
                Text(alarm.line)
                    .appText(.fine)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(Paper.wash)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(alarm.line)
        }
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
