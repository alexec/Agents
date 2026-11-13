import AgentsKitCore
import SwiftUI

/// An agent's ask to be archived (#584, #649), as an Ask at the end of the transcript, the
/// way a tool's permission question is asked (#827, #5031): what the agent last said, and
/// Archive or Keep Session. It was a grey line over the chat, and was
/// missed. The window and the Remote both draw it; the web page's is `ArchiveCard.tsx`.
struct ArchiveRequestCard: View {
    let agent: Agent
    /// Archive the session.
    let approve: () async -> Void
    /// Deny (#773): the ask goes, and the session stays.
    let keep: () async -> Void
    var isDisabled = false

    @State private var busy = false

    var body: some View {
        // An Ask (#5031): the question as the title, Keep Session and Archive in the foot.
        AskCard(icon: ArchiveRequestWords.symbol, title: ArchiveRequestWords.question) {
            Text(agent.report?.message ?? ArchiveRequestWords.noReport)
                .appText(.supporting)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } buttons: {
            Group {
                Button(ArchiveRequestWords.keep) { answer(keep) }
                    .buttonStyle(.paper)
                Button(ArchiveRequestWords.archive) { answer(approve) }
                    .buttonStyle(.paperProminent)
                    .help(ArchiveRequestWords.archiveHelp)
                    .accessibilityHint(ArchiveRequestWords.archiveHelp)
            }
            .disabled(busy || isDisabled)
        }
    }

    private func answer(_ action: @escaping () async -> Void) {
        busy = true
        Task {
            await action()
            busy = false
        }
    }
}
