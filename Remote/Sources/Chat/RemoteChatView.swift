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
    @State private var isLoadingEarlier = false
    @State private var hasSettled = false
    @State private var isShowingArtifacts = false
    /// How far the foot of the conversation is below the foot of the screen. Zero
    /// means the reader is at the live end.
    @State private var distanceFromEnd: CGFloat = 0
    /// Something arrived while the reader was up the conversation reading.
    @State private var hasNewBelow = false

    private var agent: Agent? { model.selectedAgent }

    var body: some View {
        ScrollViewReader { scroller in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if model.hasMoreBefore {
                        // No button. Reaching the top is the ask.
                        ProgressView()
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 8)
                    }
                    ForEach(model.transcriptItems) { item in
                        EntryView(item: item).id(item.id)
                    }
                    // Live, and so at the foot rather than in the record: the chat
                    // itself says what the card in the list says, and it stops saying
                    // it the moment the prompt lands.
                    if let agent, model.isComingBack(agent) {
                        ComingBackLine()
                    }
                    Color.clear.frame(height: 1).id(bottom)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .readableWidth()
            }
            .onScrollGeometryChange(for: Place.self) { Place($0) } action: { _, place in
                if place.offset < 400 { loadEarlier(keeping: scroller) }
                distanceFromEnd = place.distanceFromEnd
                // Back at the end, so there is nothing new below any more — whether
                // they got here by the button or by scrolling.
                if place.isAtEnd { hasNewBelow = false }
                // The conversation is the only thing that knows how tall it is, and
                // the page it asks for next should be sized to that (SC-007).
                model.measure(transcriptHeight: place.height)
            }
            .task(id: model.selection) { await settle(scroller) }
            .onChange(of: model.entries.count) { before, after in
                guard after > before, !isLoadingEarlier, hasSettled else { return }
                // Only when they are already at the end. Dragging somebody to the foot
                // of the conversation because a tool call landed is taking the screen
                // off the person reading it.
                guard isAtEnd else { hasNewBelow = true; return }
                withAnimation(.easeOut(duration: 0.15)) { scroller.scrollTo(bottom, anchor: .bottom) }
            }
            .overlay(alignment: .bottom) { jumpToEnd(scroller) }
        }
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
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(alignment: .trailing, spacing: 0) {
                // Over the bar's right-hand end rather than in a toolbar under it: the
                // figure belongs to the conversation, and the foot of the screen is
                // the home indicator's.
                if let agent {
                    ContextMeter(agent: agent)
                        .padding(.horizontal, 16)
                        .padding(.top, 6)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .background(Paper.ground)
                }
                question
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
        .sheet(isPresented: $isShowingArtifacts) {
            NavigationStack {
                ArtifactsList()
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") { isShowingArtifacts = false }
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
            ToolbarItem(placement: .topBarTrailing) {
                if let agent { ChatMenu(agent: agent, isShowingArtifacts: $isShowingArtifacts) }
            }
        }
    }

    /// The question, over the foot of the conversation, with the prompt bar under it.
    ///
    /// The question takes the place of the bar rather than sitting above it: an agent
    /// waiting on an answer wants the answer, and a text field beside the buttons is
    /// an invitation to type past the thing that is blocking it.
    @ViewBuilder
    private var question: some View {
        if let request = model.questionForSelection {
            // A fresh sheet per question, so a tap in flight on the last one is not
            // carried over to the next.
            PermissionSheet(request: request)
                .id(request.id)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        } else if let form = model.formForSelection {
            // The other kind of blocked, and it takes the bar for the same reason: an
            // agent waiting on an answer wants the answer, not a way to type past it.
            ElicitationSheet(request: form)
                .id(form.id)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        } else if let agent, agent.state != .archived {
            // Nothing to say to an agent that has been put away. Bringing it back is
            // in the menu, and that is the move to make first.
            PromptBar(agent: agent)
        }
    }

    private var bottom: String { "bottom" }

    /// Within a screen's-worth of the foot counts as being at the end: a reader who
    /// has nudged the scroll a little has not gone anywhere, and a button that appears
    /// for that is a button that flickers.
    private var isAtEnd: Bool { distanceFromEnd < 120 }

    /// The way back to the live end. Shown only when it would do something — there is
    /// more conversation than screen, and the reader is not already at the foot of it.
    @ViewBuilder
    private func jumpToEnd(_ scroller: ScrollViewProxy) -> some View {
        if !isAtEnd, hasSettled {
            JumpToEnd(hasNewBelow: hasNewBelow) {
                hasNewBelow = false
                withAnimation(.easeOut(duration: 0.2)) { scroller.scrollTo(bottom, anchor: .bottom) }
            }
            .padding(.bottom, 12)
            .transition(.opacity)
        }
    }

    /// Open at the end, the way every chat does, and only then let reaching the top
    /// mean something. Without the wait, a transcript that arrives a beat after the
    /// screen does would be read as "the user scrolled up" and pull the whole history
    /// in at once.
    private func settle(_ scroller: ScrollViewProxy) async {
        hasSettled = false
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while model.entries.isEmpty, ContinuousClock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(30))
        }
        guard !Task.isCancelled else { return }
        scroller.scrollTo(bottom, anchor: .bottom)
        try? await Task.sleep(for: .milliseconds(400))
        guard !Task.isCancelled else { return }
        hasNewBelow = false
        hasSettled = true
    }

    /// Another page, and the reader left looking at the line they were on. That is the
    /// difference between reading backwards through a conversation and being thrown
    /// about by it.
    private func loadEarlier(keeping scroller: ScrollViewProxy) {
        guard hasSettled, !isLoadingEarlier, model.hasMoreBefore else { return }
        isLoadingEarlier = true
        let anchor = model.transcriptItems.first?.id
        Task {
            await model.loadEarlier()
            if let anchor { scroller.scrollTo(anchor, anchor: .top) }
            try? await Task.sleep(for: .milliseconds(250))
            isLoadingEarlier = false
        }
    }
}

/// What can be done to this agent from here. A menu rather than a row of buttons: on a
/// phone the transcript is the screen, and these are the rare things.
private struct ChatMenu: View {
    @Environment(RemoteModel.self) private var model
    let agent: Agent
    @Binding var isShowingArtifacts: Bool

    var body: some View {
        Menu {
            Button("Exchanged", systemImage: "doc") { isShowingArtifacts = true }
            Divider()
            if model.canStop(agent) {
                Button("Stop", systemImage: "stop.circle") {
                    Task { await model.stop(agent.id) }
                }
                .disabled(model.isStale)
            }
            if agent.state == .archived {
                Button("Bring back", systemImage: "tray.and.arrow.up") {
                    Task { await model.unarchive(agent.id) }
                }
                .disabled(model.isStale)
            } else {
                Button("Archive", systemImage: "archivebox") {
                    Task { await model.archive(agent.id) }
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

/// Where the reader is in the conversation, in one value, because `onScrollGeometryChange`
/// fires on one.
private struct Place: Equatable {
    var offset: CGFloat
    var distanceFromEnd: CGFloat
    /// The height of the visible part, which is what a page should be sized to.
    var height: CGFloat

    init(_ geometry: ScrollGeometry) {
        offset = geometry.contentOffset.y
        height = geometry.containerSize.height
        // What is below the foot of the screen. Negative while rubber-banding past the
        // end, which is still the end, so it is floored at zero.
        distanceFromEnd = max(0, geometry.contentSize.height
                                 - geometry.containerSize.height
                                 - geometry.contentOffset.y)
    }

    var isAtEnd: Bool { distanceFromEnd < 120 }
}

/// The way back to the live end of a conversation.
///
/// The Mac's control, at a size a thumb can hit. No colour — colour means something
/// has gone wrong in this app, and being three screens up a conversation is not that.
/// New lines arriving while you read are said in words.
private struct JumpToEnd: View {
    let hasNewBelow: Bool
    let go: () -> Void

    var body: some View {
        Button(action: go) {
            HStack(spacing: 5) {
                Image(systemName: "arrow.down")
                    // Decorative: a glyph in a capsule, not text (FR-015).
                    .font(.system(size: 11, weight: .semibold))
                if hasNewBelow {
                    Text("Something new")
                }
            }
            .padding(.horizontal, hasNewBelow ? 14 : 12)
            .padding(.vertical, 10)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .appText(.fine)
        .fixedSize()
        .paperRaised(in: .capsule)
        .accessibilityLabel(hasNewBelow
                            ? "Go to the end of the conversation, where something new is"
                            : "Go to the end of the conversation")
    }
}
