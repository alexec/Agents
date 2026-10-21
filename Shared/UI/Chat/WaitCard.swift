import AgentsKitCore
import SwiftUI

/// What the open agent is waiting for (042), as a card at the end of the chat (#1995):
/// "◷ Waiting for “Fix login” to finish · since 14:02 · until 15:00", with **Stop Waiting**.
/// It was a capsule over the prompt, with a line saying that sending cancels the wait; a
/// prompt ends a wait as it does everywhere else, so that line went.
///
/// The question cards' shape, under them, since an agent waiting on an event is very like
/// one waiting for an answer. Not tinted: nothing has gone wrong, and the chat is already
/// under Waiting. One view for both apps; the web page's is `WaitCard` in `Chat.tsx`. The
/// Mac opens Events at Waiting now from it; the Remote has no Events page.
struct WaitCard: View {
    let status: WaitStatus
    var open: (() -> Void)?
    let stop: () async -> Void
    var isDisabled = false

    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(status.line)
                .appText(.reading).fontWeight(.semibold)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Spacer()
                if let open {
                    Button("Show in Events", action: open)
                        .buttonStyle(.paper)
                }
                if status.cancellable {
                    Button("Stop Waiting") {
                        busy = true
                        Task {
                            await stop()
                            busy = false
                        }
                    }
                    .buttonStyle(.paper)
                    .help("Stop waiting. Nothing will start it again for this wait.")
                    .disabled(busy || isDisabled)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.25)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(status.line)
    }
}
