import AgentsKitCore
import SwiftUI

/// One line for each server a workflow's MCP event triggers hear (#383), under its
/// triggers on the Mac's and the Remote's workflow page: whether it is being asked, when
/// the last event came, and why not. "Checked 20 s ago" is worked out here, every few
/// seconds, from when the host last said it asked.
///
/// One accessibility element per line, and Clear its own.
struct MCPTriggerLines: View {
    var statuses: [MCPTriggerStatus]
    /// The person's Clear on a line's missed events.
    var clear: (MCPTriggerStatus) -> Void
    var disabled = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 10)) { context in
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(statuses.enumerated()), id: \.offset) { _, status in
                    line(status, now: context.date)
                }
            }
        }
    }

    @ViewBuilder
    private func line(_ status: MCPTriggerStatus, now: Date) -> some View {
        let words = status.words(now: now)
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .appText(.fine)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(words.text)
                .appText(.fine)
                .foregroundStyle(words.tint.style(or: .secondary))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(words.text)
        }
        if let missed = status.missedWords {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(missed)
                    .appText(.fine)
                    .foregroundStyle(StateTint.attention.style(or: .secondary))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 26)
                    .accessibilityLabel(missed)
                Button("Clear") { clear(status) }
                    .buttonStyle(.borderless)
                    .appText(.fine)
                    .disabled(disabled)
                    .accessibilityLabel("Clear: \(missed)")
            }
        }
    }
}
