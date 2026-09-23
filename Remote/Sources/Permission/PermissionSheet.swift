import AgentsKitCore
import SwiftUI

/// The question the agent is blocked on, and the answer.
///
/// This is the screen the whole feature exists for, so it shows the question in full —
/// the command or the change it covers — and offers the agent's own options and no
/// fewer. Nothing here answers on the user's behalf, remembers an answer, or applies a
/// rule of its own.
///
/// The choices stack rather than sitting in a row. A row of three buttons at the
/// largest Dynamic Type sizes is three truncated words, and a permission the user
/// cannot read in full is one they cannot answer.
struct PermissionSheet: View {
    @Environment(RemoteModel.self) private var model
    let request: PermissionRequest

    /// Which option was tapped, while the answer is in flight. The buttons go at once
    /// so nothing is tapped twice, and what replaces them says which way it went.
    @State private var chosen: PermissionOption?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(request.toolCall.title)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                if let kind = request.toolCall.kind {
                    Text(kind).font(.caption).foregroundStyle(.secondary)
                }
            }

            detail

            if let chosen {
                Sending(option: chosen)
            } else {
                choices
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        // The same ceiling the transcript has, so the question sits over the column it
        // is about rather than across the whole iPad.
        .readableWidth()
        .animation(.snappy(duration: 0.2), value: chosen)
    }

    /// What it actually wants to do: the command, or the change. Shown, not summarised
    /// — the point of being asked is to see what is being asked.
    @ViewBuilder
    private var detail: some View {
        if !request.toolCall.content.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(request.toolCall.content.enumerated()), id: \.offset) { _, piece in
                    switch piece {
                    case .diff(let diff):
                        DiffView(diff: diff)
                    case .content(let block):
                        BlocksView(blocks: [block])
                            .font(.callout)
                    case .terminal, .unknown:
                        EmptyView()
                    }
                }
            }
        }
    }

    /// The agent's own wording, on the agent's own options.
    private var choices: some View {
        VStack(spacing: 8) {
            ForEach(request.options) { option in
                if option.kind.allows {
                    Button { answer(option) } label: { label(option) }
                        .buttonStyle(.glassProminent)
                        .controlSize(.large)
                } else {
                    Button { answer(option) } label: { label(option) }
                        .buttonStyle(.glass)
                        .controlSize(.large)
                }
            }
        }
        // An answer that cannot be delivered is refused at the moment it is taken
        // rather than appearing to be accepted (FR-033).
        .disabled(model.isStale)
    }

    /// Full width and wrapping rather than truncating, because the largest Dynamic
    /// Type sizes are exactly when a one-word button becomes half a word.
    private func label(_ option: PermissionOption) -> some View {
        Text(option.name)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func answer(_ option: PermissionOption) {
        chosen = option
        Task {
            // Left showing what was sent. What becomes of it arrives as the daemon
            // withdrawing the question, which takes this whole view away. An answer
            // that did not go gives the buttons back, so it can be given again.
            if !(await model.answer(request, optionID: option.optionID)) { chosen = nil }
        }
    }
}

/// What was sent, where the buttons were. Never a second answer.
private struct Sending: View {
    let option: PermissionOption

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("\(option.name) — telling your Mac")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
    }
}
