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
    /// Set in a window of its own (#826), which has no Files pane.
    @Environment(\.poppedChat) private var popped
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
        // An Ask (#5031): the call as the title, who asks beside it, a reject on the left as a
        // link, and the allowing answers on the right. More than two (a plan's five sentences)
        // stack in the body instead, so each can be read whole.
        AskCard(icon: request.toolCall.isPlanApproval ? "list.number" : "terminal",
                title: request.toolCall.title,
                asker: model.work.askerLine(request.agentID, subagent: request.subagent)) {
            question
            if stacks {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(allowing, id: \.option.id) { optionButton($0.option, index: $0.index) }
                }
            }
        } decline: {
            ForEach(Array(rejects.enumerated()), id: \.element.option.id) { position, item in
                if position > 0 { Text("·").foregroundStyle(.secondary) }
                AskDecline(item.option.name) { answer(item.option) }
                    .modifier(NumberShortcut(index: item.index))
                    .modifier(Held(chosen: chosen, option: item.option))
            }
        } buttons: {
            if !stacks {
                // The primary, the first allowing answer, last on the right.
                ForEach(allowing.reversed(), id: \.option.id) { optionButton($0.option, index: $0.index) }
            }
        }
        .background {
            // Return for the first allowing option without stealing its ⌘n.
            if let option = request.options.first(where: \.kind.allows) {
                Button("") { answer(option) }
                    .keyboardShortcut(.defaultAction)
                    .opacity(0)
                    .accessibilityHidden(true)
                    .disabled(chosen != nil)
            }
        }
        // At the end of the conversation, in its column (#723).
        .chatColumn()
    }

    /// The options by their place, for ⌘1…9.
    private var numbered: [(index: Int, option: PermissionOption)] {
        request.options.enumerated().map { ($0.offset, $0.element) }
    }
    private var allowing: [(index: Int, option: PermissionOption)] { numbered.filter { $0.option.kind.allows } }
    private var rejects: [(index: Int, option: PermissionOption)] { numbered.filter { !$0.option.kind.allows } }
    /// Too many allowing answers for the foot's two buttons.
    private var stacks: Bool { allowing.count > 2 }

    /// Kind and plan, or what the call will do: everything between the head and the answers.
    /// Scrolls when tall so the buttons stay reachable.
    private var question: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let kind = request.toolCall.kind, !request.toolCall.isPlanApproval {
                    Text(kind).appText(.fine).foregroundStyle(Paper.secondary)
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
                    .appText(.fine).foregroundStyle(Paper.secondary)
                Button("Show plan") { show(file) }
                    .buttonStyle(.paper)
            }
        } else if let text = request.toolCall.planText {
            Text((try? AttributedString(markdown: text, options: .init(
                interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text))
                .appText(.reading)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if !request.toolCall.content.isEmpty {
            // What it actually wants to do: the change, or what it said with it, as the
            // Remote's card shows it (#266). The card's own scroll keeps the answers in reach.
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

    /// Full width and wrapping rather than truncating.
    private func label(_ option: PermissionOption) -> some View {
        HStack(spacing: 8) {
            Text(option.name)
                .multilineTextAlignment(.leading)
                // Wraps in the width it is given. Not `fixedSize`: measured at no width, a
                // fixed-height sentence is one letter a line, and the card pushed the whole
                // window's layout a thousand points past its bottom edge.
                .frame(maxWidth: stacks ? .infinity : nil, alignment: .leading)
            if chosen?.id == option.id {
                Telling(host: model.answerRecipient(request.agentID))
            }
        }
    }

    @ViewBuilder
    private func optionButton(_ option: PermissionOption, index: Int) -> some View {
        if option.id == request.options.first(where: \.kind.allows)?.id {
            Button { answer(option) } label: { label(option) }
                .buttonStyle(.paperProminent)
                .modifier(NumberShortcut(index: index))
                .modifier(Held(chosen: chosen, option: option))
        } else {
            Button { answer(option) } label: { label(option) }
                .buttonStyle(.paper)
                .modifier(NumberShortcut(index: index))
                .modifier(Held(chosen: chosen, option: option))
        }
    }

    /// The same as the daemon's own showing of it: the files pane, open on the plan.
    private func show(_ file: ShownFile) {
        if popped != nil, let agent = model.work.agent(request.agentID) { return model.open(file.url, on: agent.host) }
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

/// While an answer is on its way: the others greyed, and the one sent left as it was
/// drawn, so its pending mark reads, but taking no more clicks.
private struct Held: ViewModifier {
    let chosen: PermissionOption?
    let option: PermissionOption

    func body(content: Content) -> some View {
        content
            .disabled(chosen != nil && chosen?.id != option.id)
            .allowsHitTesting(chosen == nil)
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
