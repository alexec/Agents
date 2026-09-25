import AgentsKit
import SwiftUI

/// What the agent has said and done.
///
/// No colour: the only thing worth a colour here is something going wrong. No icons
/// either. What a line is comes from what it says and from how it sits.
struct Transcript: View {
    @Environment(AppModel.self) private var model
    let agent: Agent
    /// How much of the foot of the pane the floating prompt covers.
    var bottomInset: CGFloat = 0
    @State private var expandedRuns: Set<UUID> = []
    /// Set once the pane is sitting at the foot of the conversation. Until then the
    /// top of the list is on screen only because nothing has moved yet, and taking
    /// that for "the reader scrolled up" would pull the whole transcript in at once.
    @State private var hasSettled = false
    @State private var isLoadingEarlier = false
    /// Whether the pane is following the end of the conversation.
    ///
    /// Not the same thing as being at the end. Being at the end is geometry, and
    /// geometry moves every time a line arrives; this is a mode, and only the reader
    /// changes it. Someone reading back through an hour of a conversation is left where
    /// they are until they ask to come back.
    @State private var isFollowing = true
    /// Whether the last thing to move the pane was a hand rather than the conversation.
    @State private var isUserScrolling = false
    /// Whether anything has arrived since they scrolled away from the end.
    ///
    /// The pane must not move while they are reading (FR-010), so the arrival is said
    /// rather than shown. Cleared the moment they are back at the end, by either route.
    @State private var hasNewBelow = false
    /// Whether there is more conversation than pane. No point offering a way to the
    /// end of something already wholly on screen.
    @State private var canScroll = false

    var body: some View {
        ScrollViewReader { scroller in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if model.transcriptHasMore {
                        // No button. Reaching the top is the ask.
                        ProgressView()
                            .controlSize(.small)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                    // Folded once by the model as each entry lands, not here on every
                    // redraw: a reply arrives several chunks a second.
                    ForEach(model.transcriptItems) { item in
                        row(for: item).id(item.id)
                    }
                    ForEach(agent.queuedPrompts) { queued in
                        QueuedPromptRow(prompt: queued, agentID: agent.id)
                    }
                    // Live, and so at the foot rather than in the record: the chat
                    // itself says what the row in the list says, and it stops saying
                    // it the moment the prompt lands.
                    if model.isComingBack(agent) {
                        ComingBackLine()
                    } else if agent.state == .running || agent.state == .starting {
                        WorkingLine()
                    }
                    Color.clear.frame(height: 1).id(bottom)
                }
                // The chat column, shared with the prompt bar below it and with the
                // cards that float above that: one pair of edges down the pane, set in
                // one place (FR-021).
                .chatColumn()
                .padding(.vertical, 20)
            }
            // The text stops above the floating prompt, and so does the scrollbar.
            // Insetting the content alone left the bar running the whole height of the
            // pane and disappearing under the glass, where it could be neither read nor
            // caught. Two lines rather than one bare `contentMargins`, because the bare
            // one moves the visible area up as well, and the transcript is meant to run
            // on under the glass rather than stop short of it.
            .contentMargins(.bottom, bottomInset, for: .scrollContent)
            .contentMargins(.bottom, bottomInset, for: .scrollIndicators)
            .onScrollGeometryChange(for: Edges.self) { geometry in
                Edges(fromTop: geometry.contentOffset.y,
                      fromBottom: geometry.contentSize.height
                          - geometry.contentOffset.y
                          - geometry.containerSize.height,
                      canScroll: geometry.contentSize.height > geometry.containerSize.height)
            } action: { _, edges in
                canScroll = edges.canScroll
                // Geometry moves for two reasons: the reader scrolled, or the
                // conversation grew. Only the first may end follow mode. Reading the
                // distance on its own got this wrong — a new line puts the end below the
                // pane for a frame before the pane catches up, and that frame looks
                // exactly like somebody scrolling away — so the pane decided the reader
                // had left when they had not, stopped following, and put the way back up
                // unasked.
                if isUserScrolling, !isLoadingEarlier, edges.fromBottom > leftTheEnd {
                    isFollowing = false
                }
                // Back at the foot under their own steam. Generous on the way in and
                // strict on the way out: following again a moment early is a small
                // wrong, and being left behind a live conversation is the bug.
                if edges.fromBottom < atTheEnd {
                    isFollowing = true
                    hasNewBelow = false
                }
                // Following the end, taken from the geometry rather than from new
                // entries arriving. It used to be an animated scrollTo per entry, and
                // that is the chunkiness: a reply arrives in fragments, several a
                // second, and each one started a fresh 0.15s ease that restarted the one
                // still running, so the pane stuttered rather than moved. The geometry
                // sees every kind of growth — a new line, a line getting longer, a tool
                // run unfolding — and there is nothing to animate: at a fragment at a
                // time the pane moves by the word as the word arrives.
                //
                // Both declarative answers were tried here first, against a live agent,
                // and neither held the foot once the content grew past it:
                // `.defaultScrollAnchor(.bottom, for: .sizeChanges)`, and a
                // `ScrollPosition` left standing at its bottom edge. With either of them
                // the offset stayed where it was while the conversation ran on below the
                // pane.
                //
                // Not guarded on `isLoadingEarlier`: earlier pages land on top, and
                // whoever is following wants the foot whatever arrives above them.
                // Guarding it cost three seconds of falling behind at the start of a
                // turn, and then the catching-up jump this is all meant to stop.
                if isFollowing, !isUserScrolling, edges.fromBottom > 0.5 {
                    scroller.scrollTo(bottom, anchor: .bottom)
                }
                // A page is 200 entries, and a run of tool calls is one line however
                // many entries it took, so a page can come back shorter than the
                // pane. Nothing to scroll means nothing would ever ask for the rest,
                // so a page that does not fill the pane asks for another itself.
                if edges.fromTop < 400 || !edges.canScroll { loadEarlier(keeping: scroller) }
            }
            // What counts as the reader moving the pane. `.animating` is this view's own
            // scrollTo and `.idle` is the conversation growing under a still hand;
            // neither is a reason to stop following.
            .onScrollPhaseChange { _, phase in
                switch phase {
                case .tracking, .interacting, .decelerating: isUserScrolling = true
                default: isUserScrolling = false
                }
            }
            .onChange(of: model.entries.count) { before, after in
                // Nothing here moves the pane; the geometry does that. This is only the
                // word to the reader who is not watching. Loading earlier adds to the
                // top, and that must not read as something new having arrived.
                guard after > before, !isLoadingEarlier, !isFollowing else { return }
                hasNewBelow = true
            }
            .task(id: model.selection) { await settle(scroller) }
            // The artifacts pane asked for the message something came from
            // (FR-042). A message entry is drawn with its own id, so this lands
            // on it.
            .onChange(of: model.focusedEntry) {
                guard let focused = model.focusedEntry else { return }
                // Being sent to a line in the middle is being sent away from the end,
                // and it was asked for. Following on from here would take the reader
                // straight back off the line they were sent to.
                isFollowing = false
                withAnimation(.easeOut(duration: 0.2)) { scroller.scrollTo(focused, anchor: .center) }
                model.clearFocus()
            }
            // Somebody asked for the end: the prompt was sent, or the menu command
            // was used. A counter rather than a flag, so two asks in a row both land.
            .onChange(of: model.scrollToEndToken) { goToEnd(scroller) }
            // The floor rose: a question or a permission card appeared above the
            // prompt bar, and the transcript's bottom margin grew with it. The
            // geometry does not count that as the end moving — content size and
            // offset are what they were — so whoever was following was left with the
            // last thing said, usually the question itself, under the glass. Only for
            // the follower: a reader elsewhere is not moved (FR-010), and the card
            // floats in view for them regardless. A turn of the run loop later, so
            // the new margin is in force before the pane is asked to reach the end.
            .onChange(of: bottomInset) { before, after in
                guard after > before, isFollowing else { return }
                Task { @MainActor in
                    withAnimation(.easeOut(duration: 0.2)) { scroller.scrollTo(bottom, anchor: .bottom) }
                }
            }
            .overlay(alignment: .bottom) {
                if canScroll, !isFollowing {
                    JumpToEnd(hasNewBelow: hasNewBelow) { goToEnd(scroller) }
                        // Clear of the floating prompt, which ChatView has already
                        // measured for the transcript's own bottom inset.
                        .padding(.bottom, bottomInset + 12)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.15), value: canScroll && !isFollowing)
        }
    }

    private func goToEnd(_ scroller: ScrollViewProxy) {
        hasNewBelow = false
        isFollowing = true
        withAnimation(.easeOut(duration: 0.2)) { scroller.scrollTo(bottom, anchor: .bottom) }
    }

    /// How far from the foot counts as having left it, and how close counts as being
    /// back at it. Two numbers rather than one: with a single line between the two
    /// states, a conversation arriving a line at a time could flip the mode back and
    /// forth under the reader.
    private var leftTheEnd: CGFloat { 160 }
    private var atTheEnd: CGFloat { 40 }

    /// How far the pane is from either end of the conversation.
    private struct Edges: Equatable {
        var fromTop: CGFloat
        var fromBottom: CGFloat
        var canScroll: Bool
    }

    /// Open at the end, the way every chat does, and only then let reaching the top
    /// mean something.
    private func settle(_ scroller: ScrollViewProxy) async {
        expandedRuns = []
        hasSettled = false
        isFollowing = true
        isUserScrolling = false
        hasNewBelow = false
        // The first page arrives a moment after the selection does. Waiting for it
        // rather than guessing at a delay is what keeps a big transcript from
        // opening halfway up itself.
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while model.entries.isEmpty, ContinuousClock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(30))
        }
        guard !Task.isCancelled else { return }
        scroller.scrollTo(bottom, anchor: .bottom)
        try? await Task.sleep(for: .milliseconds(400))
        guard !Task.isCancelled else { return }
        hasSettled = true
    }

    /// Another page, and the reader left looking at the same line they were.
    ///
    /// The anchor is the line that was at the top before the page went in. Scrolling
    /// back to it afterwards is the difference between reading backwards through a
    /// conversation and being thrown about by it.
    private func loadEarlier(keeping scroller: ScrollViewProxy) {
        guard hasSettled, !isLoadingEarlier, model.transcriptHasMore else { return }
        isLoadingEarlier = true
        let anchor = model.transcriptItems.first?.id
        Task {
            await model.loadEarlier()
            if let anchor { scroller.scrollTo(anchor, anchor: .top) }
            // A beat before the next one can start, so one flick does not swallow
            // the whole file.
            try? await Task.sleep(for: .milliseconds(250))
            isLoadingEarlier = false
        }
    }

    private var bottom: String { "bottom" }

    @ViewBuilder
    private func row(for item: TranscriptItem) -> some View {
        switch item {
        case .entry(let entry):
            EntryRow(entry: entry)
        case .toolRun(let id, let calls):
            ToolRunRow(calls: calls,
                       isExpanded: expandedRuns.contains(id),
                       toggle: {
                           if expandedRuns.contains(id) { expandedRuns.remove(id) } else { expandedRuns.insert(id) }
                       })
        }
    }
}

private struct EntryRow: View {
    let entry: TranscriptEntry

    var body: some View {
        switch entry.kind {
        case .userMessage(let text, let blocks, let from):
            // Not in the person's bubble when it is not the person's. The app asks an
            // agent that ended without saying how it went, once, and a question they
            // never typed must not be shown as though they had (FR-022).
            if from == .app {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Agents asked").appText(.fine).foregroundStyle(.tertiary)
                    BlocksView(blocks: blocks.isEmpty ? [.text(text)] : blocks)
                        .appText(.supporting)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                BlocksView(blocks: blocks.isEmpty ? [.text(text)] : blocks)
                    .appText(.reading)
                    .padding(12)
                    .paperWell(in: RoundedRectangle(cornerRadius: 12))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

        case .agentMessage(_, let text, let blocks):
            BlocksView(blocks: blocks.isEmpty ? [.text(text)] : blocks)
                .appText(.reading)

        case .agentThought(_, let text):
            Text(text)
                .appText(.supporting)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

        case .toolCall(let call), .toolCallUpdate(let call):
            // Reached only when something splits a run; a run is drawn by ToolRunRow.
            Text(call.line).appText(.supporting).foregroundStyle(.secondary)

        case .plan(let raw):
            // The shape 001 stored. Read into entries where it can be.
            PlanView(plan: Plan(planID: nil,
                                entries: (raw["entries"]?.arrayValue ?? []).compactMap(PlanEntry.init(wire:))))

        case .planUpdated(let plan):
            PlanView(plan: plan)

        case .usageRecorded:
            // Dropped by `TranscriptEntry.display` before it gets here. The cost of a
            // turn is counted where money is looked for, not said under each reply.
            EmptyView()

        case .servedRequest(let request):
            // A read that went through is dropped by `TranscriptEntry.display`; only
            // a write, a refusal or a failure reaches here.
            ServedRequestLine(request: request)

        case .elicitationAsked(let request):
            Text("Asked: \(request.title)").appText(.supporting).foregroundStyle(.secondary)

        case .elicitationAnswered(_, let summary):
            Text(summary).appText(.supporting).foregroundStyle(.secondary)

        case .compaction(let status, let summary):
            VStack(alignment: .leading, spacing: 6) {
                Text(status == "completed" ? "Made room by summarising the conversation so far"
                                           : "Summarising the conversation so far…")
                    .appText(.supporting)
                    .foregroundStyle(.secondary)
                if !summary.isEmpty {
                    BlocksView(blocks: summary).foregroundStyle(.secondary)
                }
            }

        case .permissionAsked(let request):
            Text("Asked: \(request.toolCall.title)")
                .appText(.supporting)
                .foregroundStyle(.secondary)

        case .permissionAnswered(let optionID, let name):
            Text("You chose \(name ?? optionID)")
                .appText(.supporting)
                .foregroundStyle(.secondary)

        case .optionChanged:
            // Dropped by `TranscriptEntry.display` before it gets here. Plumbing: the
            // setting in force is on the prompt controls, not in the conversation.
            EmptyView()

        case .stateChanged(let state, let reason):
            // `.finished` is dropped by `TranscriptEntry.display`: the reply ending is
            // what says the turn did. The endings that mean something all reach here.
            StateLine(state: state, reason: reason)

        case .workReported(let report):
            WorkReportLine(report: report)

        case .runtimeNote(let text):
            Text(text).appText(.fine).foregroundStyle(.secondary)

        case .unrecognised:
            // Written by a newer version of this app. Kept in the record, skipped here.
            EmptyView()
        }
    }
}

/// The agent's own account of how the work went, at the foot of the conversation.
///
/// Drawn in the manner of the other state-change lines rather than as a message from
/// the agent, because it is not one: it is the app's record of a claim. The heading is
/// the app's word for the outcome and the sentence below it is the agent's own, which
/// is the same pair the row in the list shows (FR-015).
private struct WorkReportLine: View {
    let report: WorkReport

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(report.outcome.heading)
                .appText(.supporting).fontWeight(.medium)
                .foregroundStyle((report.outcome.needsAPerson ? StateTint.attention : .none)
                                    .style(or: .secondary))
            Text(report.message)
                .appText(.supporting)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Something typed while the agent was working, sitting where it will appear.
///
/// Drawn as the message it is about to be rather than as a notice about one, in the
/// place it will take, so there is nothing to learn when it goes. Lighter, because it
/// has not happened yet, and removable, because changing your mind before it goes is
/// the whole point of being able to see it.
private struct QueuedPromptRow: View {
    @Environment(AppModel.self) private var model
    let prompt: QueuedPrompt
    let agentID: UUID

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Waiting its turn")
                    .appText(.fine)
                    .foregroundStyle(.tertiary)
                BlocksView(blocks: prompt.blocks)
                    .appText(.reading)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .paperWell(in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(.quaternary, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }

            Button {
                Task { await model.unqueue(prompt, from: agentID) }
            } label: {
                Image(systemName: "xmark")
                    .appText(.fine)
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.tertiary)
            .help("Do not send this")
            .accessibilityLabel("Remove queued prompt")
        }
    }
}

/// A run of tool calls: what it is doing now, and the rest a click away.
///
/// Folded, the run is its latest line and nothing else — no count, no chevron — and
/// clicking that line unfolds the run rather than the call, because the first thing
/// anyone wants from a folded run is to see what is in it. Unfolded, every line is
/// there and each one opens its own call. A run of one has nothing to unfold, so its
/// line opens the call straight away.
private struct ToolRunRow: View {
    let calls: [ToolCall]
    let isExpanded: Bool
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if isExpanded || calls.count == 1 {
                ForEach(Array(calls.enumerated()), id: \.offset) { _, call in
                    ToolCallLine(call: call)
                }
            } else if let latest = calls.last {
                ToolCallLine(call: latest, onClick: toggle)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One tool call: the line the runtime wrote for a person to read, and nothing else
/// until it is asked for.
///
/// A turn can be a dozen of these. Unfolding every diff, every console and every
/// argument list as it arrives buries the two sentences either side of them, so the
/// description ACP sends is what a call is by default. Click it and the rest is
/// there: what it produced, where it worked, and what the runtime actually sent.
private struct ToolCallLine: View {
    @Environment(AppModel.self) private var model
    let call: ToolCall
    /// What a click does instead of opening the call, where the line is standing in
    /// for a whole folded run.
    var onClick: (() -> Void)? = nil
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            summary
            if isExpanded { detail }
        }
    }

    // MARK: The line itself

    @ViewBuilder
    private var summary: some View {
        if let onClick {
            Button(action: onClick) { line }
                .buttonStyle(.plain)
                .help("Show the whole run")
        } else if hasDetail {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { isExpanded.toggle() }
            } label: {
                line
            }
            .buttonStyle(.plain)
            .help(isExpanded ? "Hide what it did" : "Show what it did")
        } else {
            line
        }
    }

    /// The description alone. It is the whole affordance: no chevron in front of it,
    /// so a run of calls is a run of sentences — one line each. A title with no
    /// description behind it is usually a command line or a path, and a path that
    /// wraps to three lines is three lines of a run that reads as one call per line;
    /// the whole of it is a click away in the detail, where the raw input is.
    private var line: some View {
        Text(call.line)
            .appText(.supporting)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
    }

    // MARK: What it did, once asked

    private var detail: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(call.content.enumerated()), id: \.offset) { _, piece in
                view(for: piece)
            }

            if !call.locations.isEmpty {
                // Where it did its work, openable at the line.
                HStack(spacing: 10) {
                    ForEach(call.locations) { location in
                        Button {
                            open(location)
                        } label: {
                            Text(location.line.map { "\(location.fileName):\($0)" } ?? location.fileName)
                                .appText(.fine)
                        }
                        .buttonStyle(.link)
                    }
                }
            }

            if let raw {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(raw)
                        .appText(.code)
                        .textSelection(.enabled)
                        .padding(10)
                }
                .frame(maxHeight: 260)
                .paperWell(in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Copilot and Grok send a structured diff for an edit; the Claude adapter shells
    /// out and sends console text. Both are drawn as what they are. Nothing is
    /// invented for the runtime that sends neither.
    @ViewBuilder
    private func view(for piece: ToolCallContent) -> some View {
        switch piece {
        case .diff(let diff):
            DiffView(diff: diff)
        case .content(let block):
            BlocksView(blocks: [block])
                .appText(.supporting)
                .foregroundStyle(.secondary)
        case .terminal(let id):
            TerminalOutputView(text: model.terminalOutput[id] ?? "")
        case .unknown(let raw):
            // Kept rather than dropped: shown as what the runtime sent.
            Text(Self.pretty(raw))
                .appText(.code)
                .foregroundStyle(.tertiary)
                .lineLimit(6)
        }
    }

    private func open(_ location: ToolCallLocation) {
        // The editor the Mac opens that file with, which is the one the user chose.
        NSWorkspace.shared.open(URL(filePath: location.path))
    }

    /// Whether there is anything behind the line worth unfolding it for.
    ///
    /// Asked of every line on every redraw, so it asks whether the runtime sent
    /// anything and not what — `raw` pretty-prints the lot, which for a run of
    /// thirty calls with their outputs was a good deal of JSON formatted to answer
    /// a yes or no.
    private var hasDetail: Bool {
        !call.content.isEmpty || !call.locations.isEmpty
            || call.rawInput != nil || call.rawOutput != nil || call.raw != nil
    }

    /// What the runtime sent, as it sent it. Every runtime describes its tools
    /// differently and none of that is ours to tidy.
    private var raw: String? {
        let interesting = call.rawInput ?? call.rawOutput ?? call.raw
        guard let interesting else { return nil }
        if let text = interesting.stringValue { return text }
        return Self.pretty(interesting)
    }

    private static func pretty(_ value: JSONValue) -> String {
        guard let data = try? JSONEncoder.pretty.encode(value) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}

private extension JSONEncoder {
    static let pretty: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return e
    }()
}

/// The agent is at work and the person is waiting: the same small spinner the
/// sidebar row shows, at the foot of the conversation, so the chat itself moves while
/// nothing else on it does. Live rather than recorded — it is there exactly as long
/// as the wait is, and it rides the end of the transcript as the reply arrives.
private struct WorkingLine: View {
    var body: some View {
        ProgressView()
            .controlSize(.small)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 2)
            .accessibilityLabel("Working")
    }
}

/// The chat is being picked back up by the daemon, and nobody typed for it.
private struct ComingBackLine: View {
    var body: some View {
        Label(AgentsModel.comingBackDescription, systemImage: AgentsModel.comingBackSymbol)
            .appText(.fine)
            .foregroundStyle(.secondary)
    }
}

private struct StateLine: View {
    let state: AgentState
    let reason: EndedReason?

    var body: some View {
        Text(text)
            .appText(.fine)
            // The one place in the transcript a colour earns itself: something went wrong.
            .foregroundStyle((isFailure ? StateTint.failure : .none).style(or: .secondary))
    }

    private var isFailure: Bool {
        reason == .processDied || reason == .daemonGone
    }

    private var text: String {
        switch state {
        case .running: return "Working"
        case .starting: return AgentState.startingLabel
        case .waitingOnUser: return "Waiting on you"
        // Never "Complete": that word is now reserved for an agent that said `done`
        // itself, and a turn handing itself back says nothing about the work (FR-012).
        case .finished: return "Finished"
        case .stopped:
            switch reason {
            case .cancelled: return "You stopped it"
            case .stoppedByAgent: return "The agent that started it stopped it"
            case .processDied: return "The runtime crashed"
            case .daemonGone: return "Stopped when the daemon did"
            case .maxTokens: return "Ran out of room"
            case .maxTurnRequests: return "Hit its limit"
            case .refusal: return "Refused to carry on"
            case .unrecognised: return "Stopped for a reason we do not know"
            case .costLimit: return "Reached its cost limit"
            case .endTurn, nil: return "Stopped"
            }
        case .archived: return "Archived"
        }
    }
}
