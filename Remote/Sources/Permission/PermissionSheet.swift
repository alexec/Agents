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
///
/// The question itself scrolls when it is tall. A long command or a tall diff would
/// otherwise push the answers off the foot of the phone — the card becomes unanswerable
/// by being too big to answer. So the question is capped, the way a form page is, and
/// the buttons stay under it.
struct PermissionSheet: View {
    @Environment(RemoteModel.self) private var model
    let request: PermissionRequest

    /// Which option was tapped, while the answer is in flight. The buttons go at once
    /// so nothing is tapped twice, and what replaces them says which way it went.
    @State private var chosen: PermissionOption?

    /// How tall the question wants to be, measured, so a short one is not padded out
    /// to the cap and a long one scrolls rather than pushing the buttons off screen.
    @State private var questionHeight: CGFloat = 0

    /// As tall as the question may get before it scrolls: enough for a command and a
    /// short diff, and short enough to leave the answers and the conversation above.
    private static let questionCap: CGFloat = 380

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            question

            if let chosen {
                Sending(option: chosen)
            } else {
                choices
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .paperRaised(in: RoundedRectangle(cornerRadius: 18))
        // In the chat column with the prompt under it and the conversation
        // above, as on the Mac (033).
        .chatColumn()
        .animation(.snappy(duration: 0.2), value: chosen)
    }

    /// Title, kind and what it wants to do — everything above the answers. Scrolls
    /// when tall so the buttons stay reachable.
    private var question: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    // Its subagent asking, not the agent itself (057). Still the agent's
                    // question to answer, so it is asked here and not somewhere else.
                    if let subagent = request.subagent {
                        Text("Subagent “\(subagent)” asks").appText(.fine).foregroundStyle(.secondary)
                    }
                    Text(request.toolCall.title)
                        .appText(.reading).fontWeight(.semibold)
                        .fixedSize(horizontal: false, vertical: true)
                    if let kind = request.toolCall.kind, !request.toolCall.isPlanApproval {
                        Text(kind).appText(.fine).foregroundStyle(.secondary)
                    }
                }
                detail
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { questionHeight = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: questionHeight > 0 ? min(questionHeight, Self.questionCap) : nil)
    }

    /// What it actually wants to do: the command, or the change. Shown, not summarised
    /// — the point of being asked is to see what is being asked.
    ///
    /// Except a plan the runtime wrote to a file: that is a page, opened as one, and a
    /// whole plan in this card would push the answers off the screen.
    @ViewBuilder
    private var detail: some View {
        if let plan = request.toolCall.planFile {
            Button("Show plan") { model.openPlan(plan) }
                .buttonStyle(.paper)
        } else if !request.toolCall.content.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(request.toolCall.content.enumerated()), id: \.offset) { _, piece in
                    switch piece {
                    case .diff(let diff):
                        DiffView(diff: diff)
                    case .content(let block):
                        BlocksView(blocks: [block])
                            .appText(.reading)
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
                        .buttonStyle(.paperProminent)
                        .controlSize(.large)
                } else {
                    Button { answer(option) } label: { label(option) }
                        .buttonStyle(.paper)
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
                .appText(.reading)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
    }
}
