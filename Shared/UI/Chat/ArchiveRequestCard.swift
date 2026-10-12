import AgentsKitCore
import SwiftUI

/// An agent's ask to be archived (#584, #649), as a card at the end of the transcript, the
/// way a tool's permission question is asked (#827): in the attention tint, with what the
/// agent last said, and Approve or Keep Session. It was a grey line over the chat, and was
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
        VStack(alignment: .leading, spacing: 10) {
            Label(ArchiveRequestWords.question, systemImage: ArchiveRequestWords.symbol)
                .appText(.reading).fontWeight(.semibold)
                .tinted(.attention)
            Text(agent.report?.message ?? ArchiveRequestWords.noReport)
                .appText(.supporting)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Spacer()
                Button(ArchiveRequestWords.keep) { answer(keep) }
                    .buttonStyle(.paper)
                Button(ArchiveRequestWords.archive) { answer(approve) }
                    .buttonStyle(.paperProminent)
                    .help(ArchiveRequestWords.archiveHelp)
                    .accessibilityHint(ArchiveRequestWords.archiveHelp)
            }
            .disabled(busy || isDisabled)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StateTint.attention.color?.opacity(0.07) ?? .clear, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder((StateTint.attention.color ?? .secondary).opacity(0.25)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(ArchiveRequestWords.question)
    }

    private func answer(_ action: @escaping () async -> Void) {
        busy = true
        Task {
            await action()
            busy = false
        }
    }
}
