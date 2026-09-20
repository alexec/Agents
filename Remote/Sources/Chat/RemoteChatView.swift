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
                    ForEach(TranscriptEntry.display(model.entries)) { item in
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
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, offset in
                if offset < 400 { loadEarlier(keeping: scroller) }
            }
            .task(id: model.selection) { await settle(scroller) }
            .onChange(of: model.entries.count) { before, after in
                guard after > before, !isLoadingEarlier, hasSettled else { return }
                withAnimation(.easeOut(duration: 0.15)) { scroller.scrollTo(bottom, anchor: .bottom) }
            }
        }
        .navigationTitle(agent?.title ?? "Agent")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .top, spacing: 0) { StaleBanner() }
        .safeAreaInset(edge: .bottom, spacing: 0) { question }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if let agent { ChatMenu(agent: agent) }
            }
            ToolbarItem(placement: .bottomBar) {
                if let agent { ContextMeter(agent: agent) }
            }
        }
    }

    /// The question, sitting over the foot of the conversation where the prompt bar
    /// will be. Nothing else is worth covering the transcript for.
    @ViewBuilder
    private var question: some View {
        if let request = model.questionForSelection {
            PermissionSheet(request: request)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private var bottom: String { "bottom" }

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
        hasSettled = true
    }

    /// Another page, and the reader left looking at the line they were on. That is the
    /// difference between reading backwards through a conversation and being thrown
    /// about by it.
    private func loadEarlier(keeping scroller: ScrollViewProxy) {
        guard hasSettled, !isLoadingEarlier, model.hasMoreBefore else { return }
        isLoadingEarlier = true
        let anchor = TranscriptEntry.display(model.entries).first?.id
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

    var body: some View {
        Menu {
            if agent.state.holdsRuntime {
                Button("Stop", systemImage: "stop.circle") {
                    Task { await model.stop(agent.id) }
                }
            }
            if agent.state == .archived {
                Button("Bring back", systemImage: "tray.and.arrow.up") {
                    Task { await model.unarchive(agent.id) }
                }
            } else {
                Button("Archive", systemImage: "archivebox") {
                    Task { await model.archive(agent.id) }
                }
            }
        } label: {
            Label("Actions", systemImage: "ellipsis.circle")
        }
        .disabled(model.isStale)
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
        .font(.footnote)
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
                .formatted(.currency(code: agent.usage?.cost?.currency ?? "USD"))
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
