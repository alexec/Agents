import AgentsKitCore
import SwiftUI

/// A question the agent is blocked on, with the agent's own answers.
///
/// Nothing here answers on the user's behalf, remembers an answer, or applies a rule of
/// its own. The way to be asked less often is the runtime's own options, which the
/// prompt bar already offers.
///
/// The answers stack rather than sitting in a row. Approving a plan offers five, each a
/// sentence ("Yes, clear context and use auto mode"), and a row of those is five
/// truncated words: an answer the person cannot read is one they cannot give.
///
/// The question itself scrolls when it is tall. Drawn all at once, a long command or
/// plan pushes the answers off the foot of the window — the card becomes unanswerable
/// by being too big to answer. So the question is capped, the way an elicitation page
/// is, and the buttons stay under it.
struct PermissionView: View {
    @Environment(AppModel.self) private var model
    @Environment(SidebarFrame.self) private var frame
    @Environment(SidebarStates.self) private var states
    let request: PermissionRequest

    /// Which option was clicked, while its answer is on the way. Every answer is held
    /// meanwhile, so a double click or a repeated ⌘1 is not a second one, and the one
    /// that went says so. Put back if it did not go (#86).
    @State private var chosen: PermissionOption?

    /// How tall the question wants to be, measured, so a short one is not padded out
    /// to the cap and a long one scrolls rather than pushing the buttons off screen.
    @State private var questionHeight: CGFloat = 0

    /// As tall as the question may get before it scrolls — beside the caps a long
    /// diff and an elicitation page keep.
    private static let questionCap: CGFloat = 260

    var body: some View {
        GlassEffectContainer(spacing: 10) {
            VStack(alignment: .leading, spacing: 10) {
                question
                VStack(alignment: .leading, spacing: 6) {
                    // The agent's own wording, on the agent's own options.
                    // Return takes the first allowing answer; ⌘1…n pick by position
                    // (View ▸ panes yield those keys while this card is up).
                    ForEach(Array(request.options.enumerated()), id: \.element.id) { index, option in
                        optionButton(option, index: index)
                    }
                }
                .background {
                    // Return for the first allowing option without stealing its ⌘n.
                    if let option = request.options.first(where: \.kind.allows) {
                        Button("") { answer(option) }
                            .keyboardShortcut(.defaultAction)
                            .opacity(0)
                            .accessibilityHidden(true)
                    }
                }
                .disabled(chosen != nil)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .paperRaised(in: RoundedRectangle(cornerRadius: 16))
        }
        // Floats above the prompt bar, in its column.
        .chatColumn()
    }

    /// Title, kind and plan — everything above the answers. Scrolls when tall so the
    /// buttons stay reachable.
    private var question: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                // Its subagent asking, not the agent itself (057). Still the agent's
                // question to answer, so it is asked here and not somewhere else.
                if let subagent = request.subagent {
                    Text("Subagent “\(subagent)” asks").appText(.fine).foregroundStyle(.secondary)
                }
                Text(request.toolCall.title).appText(.reading).fontWeight(.semibold)
                if let kind = request.toolCall.kind, !request.toolCall.isPlanApproval {
                    Text(kind).appText(.fine).foregroundStyle(.secondary)
                }
                plan
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { questionHeight = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: questionHeight > 0 ? min(questionHeight, Self.questionCap) : nil)
    }

    /// The plan being approved. As a page in the files pane when the runtime wrote it
    /// to a file — opened there by the daemon when it was asked — and here, in the
    /// card, when it only sent the text. The card's own scroll is what keeps a long
    /// plan from pushing the answers off; no second scroller inside.
    @ViewBuilder
    private var plan: some View {
        if let file = request.toolCall.planFile {
            HStack(spacing: 8) {
                Text("The plan is open beside this conversation.")
                    .appText(.fine).foregroundStyle(.secondary)
                Button("Show plan") { show(file) }
                    .buttonStyle(.paper)
            }
        } else if let text = request.toolCall.planText {
            Text((try? AttributedString(markdown: text, options: .init(
                interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text))
                .appText(.reading)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Full width and wrapping rather than truncating.
    private func label(_ option: PermissionOption) -> some View {
        HStack(spacing: 8) {
            Text(option.name)
                .multilineTextAlignment(.leading)
                // Wraps in the width it is given. Not `fixedSize`: measured at no width, a
                // fixed-height sentence is one letter a line, and the card pushed the whole
                // window's layout a thousand points past its bottom edge.
                .frame(maxWidth: .infinity, alignment: .leading)
            if chosen?.id == option.id {
                Telling(host: model.answerRecipient(request.agentID))
            }
        }
    }

    @ViewBuilder
    private func optionButton(_ option: PermissionOption, index: Int) -> some View {
        if option.kind.allows {
            Button { answer(option) } label: { label(option) }
                .buttonStyle(.paperProminent)
                .modifier(NumberShortcut(index: index))
        } else {
            Button { answer(option) } label: { label(option) }
                .buttonStyle(.paper)
                .modifier(NumberShortcut(index: index))
        }
    }

    /// The same as the daemon's own showing of it: the files pane, open on the plan.
    private func show(_ file: ShownFile) {
        let state = states.state(for: request.agentID)
        state.folder = file.url.deletingLastPathComponent()
        state.openFile = file.url
        state.openLine = nil
        frame.pane = .files
        if !frame.isOpen { frame.open() }
    }

    private func answer(_ option: PermissionOption) {
        // Two key presses can land before the disabled buttons are drawn.
        guard chosen == nil else { return }
        chosen = option
        Task {
            // Left showing what was sent: what becomes of it arrives as the daemon
            // withdrawing the question, which takes this card away.
            if !(await model.answer(request, optionID: option.optionID)) { chosen = nil }
        }
    }
}

/// ⌘1 through ⌘9 for the first nine options; later ones are click-only.
private struct NumberShortcut: ViewModifier {
    let index: Int

    @ViewBuilder
    func body(content: Content) -> some View {
        if index < 9 {
            content.keyboardShortcut(KeyEquivalent(Character("\(index + 1)")))
        } else {
            content
        }
    }
}
