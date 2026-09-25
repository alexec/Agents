import AgentsKitCore
import SwiftUI

/// The conversation: what the agent has said and done, and the question it is stuck on.
///
/// The third level, reached by a push with a back button, never a third column. It
/// opens at the end and asks backwards as the reader scrolls up, because an hour of
/// transcript is not something to fetch over a mobile connection to show the last
/// paragraph of.
struct RemoteChatView: View {
    @Environment(RemoteModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// How much of the foot of the screen the prompt area and any card above it cover.
    @State private var formHeight: CGFloat = 0

    private var agent: Agent? { model.selectedAgent }

    var body: some View {
        if let agent {
            // The conversation with its panes beside it or over it (034).
            PaneHost(agent: agent) { conversation }
        } else {
            conversation
        }
    }

    private var conversation: some View {
        // The Mac's shape (033): the conversation runs the full height and the prompt
        // area floats over its foot, with a question floating above that. The
        // conversation is told how tall they are so the last thing said can still be
        // scrolled clear of them.
        ZStack(alignment: .bottom) {
            if let agent {
                ChatTranscript(agent: agent,
                               items: model.transcriptItems,
                               hasMore: model.hasMoreBefore,
                               entryCount: model.entries.count,
                               isComingBack: model.isComingBack(agent),
                               settleKey: model.selection,
                               loadEarlier: { await model.loadEarlier() },
                               bottomInset: formHeight,
                               scrollToEndToken: model.scrollToEndToken,
                               // The conversation is the only thing that knows how tall
                               // it is, and the page it asks for next should be sized to
                               // that (SC-007).
                               onHeight: { model.measure(transcriptHeight: $0) })
            }
            form
        }
        .environment(\.chatActions, actions)
        .navigationTitle(agent?.title ?? "Agent")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                StaleBanner()
                // Under the banner, not over it: when the Mac has gone quiet, what
                // the agent last said it would do is the less urgent of the two.
                if let agent { CurrentPlanStrip(agent: agent) }
            }
        }
        .sheet(isPresented: Binding(get: { model.fileOnScreen != nil },
                                    set: { if !$0 { model.fileOnScreen = nil } })) {
            // A look-aside, not a level. On the Mac this is a pane beside the
            // conversation; a sheet is what that is on a screen with one column.
            NavigationStack {
                if let path = model.fileOnScreen {
                    FileView(path: path)
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button("Done") { model.fileOnScreen = nil }
                            }
                        }
                }
            }
            .paperSheet()
        }
        // The agent asking to be looked at. An event, so it opens the moment it
        // arrives and is taken off the model in the same breath.
        .onChange(of: model.fileTheAgentWants) { _, wanted in
            if wanted != nil { model.openFileTheAgentWants() }
        }
        .toolbar {
            // The Mac's two verbs, where the Mac has them (033). Stop keeps the chat
            // on screen, because someone who stops a chat that has gone the wrong way
            // wants to keep reading it and say what next. Archive goes back to the
            // project, because the thing being read has been put away.
            if let agent, model.canStop(agent) {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await model.stop(agent.id) }
                    } label: {
                        Label("Stop", systemImage: "stop.circle")
                    }
                    .disabled(model.isStale)
                    .accessibilityHint("Stops this agent and stays on the chat")
                }
            }
            if let agent, agent.state != .archived {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task {
                            await model.archive(agent.id)
                            model.selection = nil
                        }
                    } label: {
                        Label("Archive", systemImage: "archivebox")
                    }
                    .disabled(model.isStale)
                    .accessibilityHint("Archives this chat and goes back to the project")
                }
            }
            if let agent {
                ToolbarItem(placement: .topBarTrailing) {
                    // The Mac's side panes: Page, Files, Terminal, Exchanged (034). One
                    // tap opens the last one used; the switch at its top reaches the rest.
                    Button {
                        let state = model.panes.state(for: agent.id)
                        if state.pane == nil { state.show(state.defaultPane) } else { state.pane = nil }
                    } label: {
                        Label("Panes", systemImage: sizeClass == .regular ? "sidebar.right" : "doc.text")
                    }
                    .accessibilityHint("Shows the page, files and terminal for this agent")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    ChatMenu(agent: agent)
                }
            }
        }
    }

    /// The question, the form and the prompt, floating over the foot of the
    /// conversation in its column, as on the Mac (FR-018).
    ///
    /// The prompt stays under a question rather than giving way to it, so what would be
    /// typed past it is in view. The question card keeps the phone's own shape — its
    /// options stacked and what it covers shown in full — because a row of buttons at
    /// a large text size is a row of truncated words.
    private var form: some View {
        VStack(spacing: 12) {
            if let request = model.questionForSelection {
                // A fresh sheet per question, so a tap in flight on the last one is not
                // carried over to the next.
                PermissionSheet(request: request)
                    .id(request.id)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if let form = model.formForSelection {
                ElicitationSheet(request: form)
                    .id(form.id)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if let agent, agent.state != .archived {
                // Nothing to say to an agent that has been put away. Bringing it back is
                // in the menu, and that is the move to make first.
                PromptBar(agent: agent, isQuestionUp: isQuestionUp)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { formHeight = $0 }
        .animation(.snappy(duration: 0.2), value: isQuestionUp)
    }

    private var isQuestionUp: Bool {
        model.questionForSelection != nil || model.formForSelection != nil
    }

    /// What the shared chat rows mean on a phone (033). A file a tool call touched
    /// opens the change the agent made to it, in a sheet: the phone cannot open the
    /// Mac's disk, and that is the one deliberate difference in these rows.
    private var actions: ChatActions {
        ChatActions(
            open: { [model] location in model.fileOnScreen = location.path },
            terminalOutput: { [model] id in model.terminalOutput(id) },
            unqueue: { [model] prompt, agentID in await model.unqueue(prompt, from: agentID) })
    }
}

/// The rarer things to do with this agent. Stop and Archive are buttons in the bar, as
/// on the Mac (033); what is left here is what the Mac keeps elsewhere.
private struct ChatMenu: View {
    @Environment(RemoteModel.self) private var model
    let agent: Agent

    var body: some View {
        Menu {
            Button("Exchanged", systemImage: "doc") { model.panes.state(for: agent.id).show(.exchanged) }
            if agent.state == .archived {
                Divider()
                Button("Bring back", systemImage: "tray.and.arrow.up") {
                    Task { await model.unarchive(agent.id) }
                }
                .disabled(model.isStale)
            }
        } label: {
            Label("Actions", systemImage: "ellipsis.circle")
        }
    }
}

/// How full the agent's context is, and what it has cost. The size is as reported and
/// never estimated, so a runtime that sends none shows no ring; the cost is always
/// shown, falling back to zero, so the figure never disappears mid-session.
struct ContextMeter: View {
    @Environment(RemoteModel.self) private var model
    let agent: Agent

    var body: some View {
        HStack(spacing: 8) {
            if let usage = agent.usage, let fraction = usage.fraction {
                ZStack {
                    Circle().stroke(.quaternary, lineWidth: 2)
                    Circle()
                        .trim(from: 0, to: fraction)
                        .stroke((usage.isCloseToFull ? StateTint.failure : .none)
                                    .style(or: .secondary),
                                style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 12, height: 12)
                .accessibilityLabel(label(usage))
            }
            Text(cost)
                .monospacedDigit()
                .foregroundStyle((isCloseToItsLimit ? StateTint.failure : .none)
                                    .style(or: .secondary))
        }
        .appText(.fine)
    }

    /// The running total and what is left of the limit, matching the window exactly.
    ///
    /// Until the first turn ends there is no total, so the figure the runtime quotes
    /// mid-turn stands in — still its own number — and before anything has been
    /// priced at all, a plain zero. A runtime that reports no price is named as
    /// unmeasured rather than shown as within a limit it cannot be held to.
    private var cost: String {
        if agent.costIsUnmeasured { return "Not measured" }
        let spent = Cost.total(of: agent.costToDate)
            ?? (agent.usage?.cost?.amount ?? 0)
                .money(in: agent.usage?.cost?.currency ?? "USD")
        guard let ceiling = agent.ceiling(under: model.costLimits) else { return spent }
        return "\(spent) of \(ceiling.amount.formatted(.currency(code: ceiling.currency)))"
    }

    /// The app's existing threshold for a nearly full context, not a second number.
    private var isCloseToItsLimit: Bool {
        guard let ceiling = agent.ceiling(under: model.costLimits), ceiling.amount > 0,
              !agent.costIsUnmeasured else { return false }
        return ((agent.costToDate[ceiling.currency] ?? 0) / ceiling.amount)
            >= Decimal(Usage.closeToFull)
    }

    private func label(_ usage: Usage) -> String {
        let tokens = "\(usage.used.formatted()) of \(usage.size.formatted()) tokens"
        return usage.isCloseToFull ? "Context nearly full — \(tokens)" : tokens
    }
}
