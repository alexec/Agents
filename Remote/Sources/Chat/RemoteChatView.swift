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
    /// The subagent whose steps are open, by its id (057).
    @State private var subagentOnScreen: String?
    /// The level every turn starts at, chosen from the ··· menu (069).
    @AppStorage(TurnDetail.phoneDefaultsKey) private var turnDetail = TurnDetail.outcome
    @Environment(\.openURL) private var openURL
    /// The open chat's views (#187), torn down when another chat opens.
    @State private var views = AppViewStore()

    private var agent: Agent? { model.selectedAgent }

    var body: some View {
        Group {
            if let agent {
                // The conversation with its panes beside it or over it (034).
                PaneHost(agent: agent) { conversation }
            } else {
                conversation
            }
        }
        // What its prompt bar reads: the runtime's capabilities, the cost limit, the
        // sandbox default and what the agent holds (#175).
        .shows([.runtimes, .costs, .sandbox, .leases])
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
                               stored: model.work.turns,
                               defaultDetail: turnDetail,
                               hasMore: model.work.hasMoreOfTheConversation,
                               entryCount: model.entries.count + model.work.turns.count,
                               isComingBack: model.isComingBack(agent),
                               settleKey: model.selection,
                               loadEarlier: { await model.loadEarlier() },
                               bottomInset: formHeight,
                               scrollToEndToken: model.scrollToEndToken,
                               // The conversation is the only thing that knows how tall
                               // it is, and the page it asks for next should be sized to
                               // that (SC-007).
                               onHeight: { model.measure(transcriptHeight: $0) },
                               onFollowing: { model.work.isFollowingEnd = $0 })
            }
            form
        }
        // Right to left across the chat brings what was exchanged in from that side, as
        // the Mac's two-finger swipe does. Left to right stays the system's Back.
        .simultaneousGesture(
            DragGesture(minimumDistance: 30)
                .onEnded { drag in
                    guard let agent, drag.translation.width < -80,
                          abs(drag.translation.width) > abs(drag.translation.height) * 2 else { return }
                    model.panes.state(for: agent.id).show(.exchanged)
                }
        )
        .environment(\.chatActions, actions)
        .environment(\.appViewStore, views)
        .environment(\.appViewActions, agent.map(appViewActions))
        // A view full screen is drawn in the chat's place, as on the Mac (#187).
        .overlay {
            if let id = views.fullscreen, let host = views.existing(id) {
                AppViewFullscreen(host: host)
            }
        }
        .onChange(of: agent?.id) { views.tearDownAll() }
        .onDisappear { views.tearDownAll() }
        .navigationTitle(agent?.title ?? "Agent")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                StaleBanner()
                if let agent {
                    RemoteSessionLabels(agent: agent, compact: false)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                // Its folder gone (#119): which, and the ways on, before anything is typed.
                if let agent, agent.missingFolder != nil, agent.state != .archived {
                    RemoteMissingFolderStrip(agent: agent)
                }
                // Why it is under Parked, and since when (040, FR-011).
                if let line = ParkWords.line(agent?.parking) {
                    Label(line, systemImage: ParkWords.symbol)
                        .appText(.fine)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                // Under the banner, not over it: when the Mac has gone quiet, what
                // the agent last said it would do is the less urgent of the two.
                if let agent { CurrentPlanStrip(agent: agent) }
                // The agent asked to be looked at while something was being typed: said
                // here, to be opened when the person chooses (034 FR-005).
                if let wanted = model.fileTheAgentWants { OfferedFileStrip(file: wanted) }
            }
        }
        .sheet(isPresented: Binding(get: { model.fileOnScreen != nil },
                                    set: { if !$0 { model.fileOnScreen = nil } })) {
            // A look-aside, not a level. On the Mac this is a pane beside the
            // conversation; a sheet is what that is on a screen with one column.
            NavigationStack {
                if let path = model.fileOnScreen {
                    ChangesView(path: path)
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button("Done") { model.fileOnScreen = nil }
                            }
                        }
                }
            }
            .paperSheet()
        }
        .sheet(isPresented: Binding(get: { subagentOnScreen != nil },
                                    set: { if !$0 { subagentOnScreen = nil } })) {
            NavigationStack {
                if let id = subagentOnScreen,
                   let item = agent?.background.first(where: { $0.id == id }) {
                    SubagentStepsView(item: item, entries: model.entries)
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button("Done") { subagentOnScreen = nil }
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
            // Stop is the prompt's own button while the agent works, as on the Mac;
            // Archive is on the session's row.
            // Blocked (039): the card's Carry on, where the chat's own controls are.
            if let agent, model.isBlocked(agent) {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await model.carryOn(agent.id) }
                    } label: {
                        Label(AgentsModel.carryOnLabel, systemImage: "play.circle")
                    }
                    .disabled(model.isStale)
                    .accessibilityHint(AgentsModel.carryOnHelp(for: agent))
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
            if !model.questionsForSelection.isEmpty {
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(model.questionsForSelection) { request in
                            // A fresh sheet per question, so a tap in flight on the last one is not
                            // carried over to the next.
                            PermissionSheet(request: request)
                                .id(request.id)
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }
                }
                .frame(maxHeight: 300)
                .fixedSize(horizontal: false, vertical: true)
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
        !model.questionsForSelection.isEmpty || model.formForSelection != nil
    }

    /// What the shared chat rows mean on a phone. A file a tool call touched opens as it
    /// is now, in Files at the line the call named, with what the agent did one tap from
    /// there (034 FR-014). A Mac too old to read files for the phone gets 033's sheet of
    /// the change instead.
    private var actions: ChatActions {
        ChatActions(
            open: { [model] location in
                guard !model.macLacksPanes, let agentID = model.selection else {
                    model.fileOnScreen = location.path
                    return
                }
                model.panes.state(for: agentID).open(file: URL(filePath: location.path), line: location.line)
            },
            terminalOutput: { [model] id in model.terminalOutput(id) },
            unqueue: { [model] prompt, agentID in await model.unqueue(prompt, from: agentID) },
            sendNow: { [model] prompt, agentID in await model.sendNow(prompt, to: agentID) },
            canSendNow: { [model] runtimeID in model.canSteer(runtimeID) },
            acting: { [model] agentID in model.acting(agentID) },
            // A subagent's own steps, in a sheet: the Mac's Background pane, on a phone
            // (057, frame E).
            subagentSteps: { id in subagentOnScreen = id },
            turnEntries: { [model] agentID, range in await model.turnEntries(agentID, range) },
            continueWithoutSandbox: sandboxAnswer(carryOn: true),
            keepStopped: sandboxAnswer(carryOn: false),
            waitingSandbox: waitingSandbox)
    }

    /// What a view in the chat may ask of the phone (#187): the Mac it is on, the person's
    /// own send, and the browser.
    private func appViewActions(_ agent: Agent) -> AppViewActions {
        AppViewActions(
            agentID: agent.id,
            call: { [model] method, params in try await model.viewCall(method, params) },
            send: { [model] text in await model.send(text, to: agent.id) },
            openLink: { [openURL] url in openURL(url) })
    }

    /// The open agent's sandbox card, while it waits (064).
    private var waitingSandbox: SandboxFailureRecord? {
        model.selection.flatMap { model.agent($0) }?.pendingSandboxFailure
    }

    private func sandboxAnswer(carryOn: Bool) -> (@MainActor () async -> Void)? {
        guard waitingSandbox != nil, let id = model.selection else { return nil }
        let model = model
        return { await model.answerSandbox(id, carryOn: carryOn) }
    }
}

/// The rarer things to do with this agent. Stop and Archive are buttons in the bar, as
/// on the Mac (033); what is left here is what the Mac keeps elsewhere.
private struct ChatMenu: View {
    @Environment(RemoteModel.self) private var model
    @AppStorage(TurnDetail.phoneDefaultsKey) private var turnDetail = TurnDetail.outcome
    let agent: Agent

    var body: some View {
        Menu {
            // What every turn starts at, above the chat's own actions (069, frame F).
            Picker("Turns show", selection: $turnDetail) {
                ForEach(TurnDetail.allCases, id: \.self) { detail in
                    Text(detail.title).tag(detail)
                }
            }
            .pickerStyle(.inline)
            Divider()
            Button("Exchanged", systemImage: "doc") { model.panes.state(for: agent.id).show(.exchanged) }
            if agent.state == .archived {
                Divider()
                Button("Bring Back", systemImage: "tray.and.arrow.up") {
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

/// "Wants you to see plan.md", with Open and not now (034 FR-005).
///
/// The agent's request, kept on the chat rather than taking the screen: somebody typing
/// is not somebody to interrupt, and the file will still be there when they are done.
private struct OfferedFileStrip: View {
    @Environment(RemoteModel.self) private var model
    let file: ShownFile

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: ShownFile.isMarkdown(file.url) ? "doc.richtext" : "doc.text")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Wants you to see \(Text(file.name).fontWeight(.semibold))")
                .appText(.supporting)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Button("Open") { model.openOfferedFile() }
                .buttonStyle(.paper)
            Button {
                model.dismissOfferedFile()
            } label: {
                Label("Not now", systemImage: "xmark")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .paperWell(in: Rectangle())
    }
}
