import AgentsKitCore
import SwiftUI

/// What the open agent is waiting for, above the prompt bar (042 FR-012; wireframes §2):
/// "◷ Waiting for pull_request.merged #44 · since 23:30 · until 09:00", and under it the
/// one line saying that sending takes the wait's place (FR-013).
///
/// One view for both apps, beside 036's lease row. Nothing is tinted: the chat is
/// already grouped under Blocked, and that is its look. What differs by app comes in as
/// closures. The Mac opens Events at Waiting now, and has ✕. The phone has neither: it
/// cancels only by sending, and the hint says so.
struct WaitCapsule: View {
    let status: WaitStatus
    /// "Sending will cancel the wait on …".
    let hint: String
    var open: (() -> Void)?
    var cancel: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Button {
                    open?()
                } label: {
                    Text(status.line)
                        .appText(.fine)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .buttonStyle(.plain)
                .disabled(open == nil)
                .help(status.line)
                if let cancel {
                    Button(action: cancel) {
                        Image(systemName: "xmark").font(.caption2) // decorative glyph
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Stop waiting. Nothing will start it again for this wait.")
                    .accessibilityLabel("Stop waiting")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .paperRaised(in: Capsule())
            Text(hint)
                .appText(.fine)
                .foregroundStyle(.tertiary)
        }
    }
}
