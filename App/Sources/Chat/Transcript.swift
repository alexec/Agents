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
    /// Whether the reader is at the end. The conversation follows itself only while
    /// they are: someone reading back through an hour of it is left where they are.
    @State private var isAtEnd = true

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
                    ForEach(TranscriptEntry.display(model.entries)) { item in
                        row(for: item).id(item.id)
                    }
                    ForEach(agent.queuedPrompts) { queued in
                        QueuedPromptRow(prompt: queued, agentID: agent.id)
                    }
                    Color.clear.frame(height: 1).id(bottom)
                }
                // Lines up with the prompt bar below it: one left edge down the pane.
                .padding(.horizontal, 144)
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentMargins(.bottom, bottomInset, for: .scrollContent)
            .onScrollGeometryChange(for: Edges.self) { geometry in
                Edges(fromTop: geometry.contentOffset.y,
                      fromBottom: geometry.contentSize.height
                          - geometry.contentOffset.y
                          - geometry.containerSize.height,
                      canScroll: geometry.contentSize.height > geometry.containerSize.height)
            } action: { _, edges in
                isAtEnd = edges.fromBottom < 160
                // A page is 200 entries, and a run of tool calls is one line however
                // many entries it took, so a page can come back shorter than the
                // pane. Nothing to scroll means nothing would ever ask for the rest,
                // so a page that does not fill the pane asks for another itself.
                if edges.fromTop < 400 || !edges.canScroll { loadEarlier(keeping: scroller) }
            }
            .onChange(of: model.entries.count) { before, after in
                // Only new lines at the end move the pane. Loading earlier adds to
                // the top, and that must not throw the reader back down to the foot.
                guard after > before, !isLoadingEarlier, isAtEnd else { return }
                withAnimation(.easeOut(duration: 0.15)) { scroller.scrollTo(bottom, anchor: .bottom) }
            }
            .onChange(of: agent.queuedPrompts.count) {
                guard isAtEnd else { return }
                withAnimation(.easeOut(duration: 0.15)) { scroller.scrollTo(bottom, anchor: .bottom) }
            }
            .task(id: model.selection) { await settle(scroller) }
            // The artifacts pane asked for the message something came from
            // (FR-042). A message entry is drawn with its own id, so this lands
            // on it.
            .onChange(of: model.focusedEntry) {
                guard let focused = model.focusedEntry else { return }
                withAnimation(.easeOut(duration: 0.2)) { scroller.scrollTo(focused, anchor: .center) }
                model.clearFocus()
            }
        }
    }

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
        isAtEnd = true
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
        let anchor = TranscriptEntry.display(model.entries).first?.id
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
        case .userMessage(let text, let blocks):
            BlocksView(blocks: blocks.isEmpty ? [.text(text)] : blocks)
                .padding(12)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
                .frame(maxWidth: .infinity, alignment: .leading)

        case .agentMessage(_, let text, let blocks):
            BlocksView(blocks: blocks.isEmpty ? [.text(text)] : blocks)

        case .agentThought(_, let text):
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

        case .toolCall(let call), .toolCallUpdate(let call):
            // Reached only when something splits a run; a run is drawn by ToolRunRow.
            Text(call.title).font(.callout).foregroundStyle(.secondary)

        case .plan(let raw):
            // The shape 001 stored. Read into entries where it can be.
            PlanView(plan: Plan(planID: nil,
                                entries: (raw["entries"]?.arrayValue ?? []).compactMap(PlanEntry.init(wire:))))

        case .planUpdated(let plan):
            PlanView(plan: plan)

        case .usageRecorded(let usage):
            UsageLine(usage: usage)

        case .servedRequest(let request):
            ServedRequestLine(request: request)

        case .elicitationAsked(let request):
            Text("Asked: \(request.title)").font(.callout).foregroundStyle(.secondary)

        case .elicitationAnswered(_, let summary):
            Text(summary).font(.callout).foregroundStyle(.secondary)

        case .compaction(let status, let summary):
            VStack(alignment: .leading, spacing: 6) {
                Text(status == "completed" ? "Made room by summarising the conversation so far"
                                           : "Summarising the conversation so far…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if !summary.isEmpty {
                    BlocksView(blocks: summary).foregroundStyle(.secondary)
                }
            }

        case .permissionAsked(let request):
            Text("Asked: \(request.toolCall.title)")
                .font(.callout)
                .foregroundStyle(.secondary)

        case .permissionAnswered(let optionID, let name):
            Text("You chose \(name ?? optionID)")
                .font(.callout)
                .foregroundStyle(.secondary)

        case .optionChanged(let id, let value):
            Text("\(id) is now \(value.stringValue ?? "changed")")
                .font(.caption)
                .foregroundStyle(.secondary)

        case .stateChanged(let state, let reason):
            StateLine(state: state, reason: reason)

        case .runtimeNote(let text):
            Text(text).font(.caption).foregroundStyle(.secondary)

        case .unrecognised:
            // Written by a newer version of this app. Kept in the record, skipped here.
            EmptyView()
        }
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
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                BlocksView(blocks: prompt.blocks)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.18), in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(.quaternary, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }

            Button {
                Task { await model.unqueue(prompt, from: agentID) }
            } label: {
                Image(systemName: "xmark")
                    .font(.caption)
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.tertiary)
            .help("Do not send this")
        }
    }
}

/// A run of tool calls: what it is doing now, and the rest a click away.
private struct ToolRunRow: View {
    let calls: [ToolCall]
    let isExpanded: Bool
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if isExpanded {
                ForEach(Array(calls.enumerated()), id: \.offset) { _, call in
                    ToolCallLine(call: call)
                }
                Button("Show less", action: toggle)
                    .buttonStyle(.link)
                    .font(.caption)
            } else {
                if let latest = calls.last { ToolCallLine(call: latest) }
                if calls.count > 1 {
                    Button("\(calls.count - 1) more", action: toggle)
                        .buttonStyle(.link)
                        .font(.caption)
                }
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
        if hasDetail {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { isExpanded.toggle() }
            } label: {
                line(chevron: true)
            }
            .buttonStyle(.plain)
            .help(isExpanded ? "Hide what it did" : "Show what it did")
        } else {
            line(chevron: false)
        }
    }

    /// The chevron keeps its place whether or not there is one, so a run of calls has
    /// one left edge rather than a ragged one.
    private func line(chevron: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .opacity(chevron ? 1 : 0)
                .frame(width: 8, alignment: .leading)
            Text(call.title)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
        }
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
                                .font(.caption)
                        }
                        .buttonStyle(.link)
                    }
                }
            }

            if let raw {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(raw)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .padding(10)
                }
                .frame(maxHeight: 260)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        // Lines up under the title rather than under the chevron.
        .padding(.leading, 14)
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
                .font(.callout)
                .foregroundStyle(.secondary)
        case .terminal(let id):
            TerminalOutputView(text: model.terminalOutput[id] ?? "")
        case .unknown(let raw):
            // Kept rather than dropped: shown as what the runtime sent.
            Text(Self.pretty(raw))
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
                .lineLimit(6)
        }
    }

    private func open(_ location: ToolCallLocation) {
        // The editor the Mac opens that file with, which is the one the user chose.
        NSWorkspace.shared.open(URL(filePath: location.path))
    }

    /// Whether there is anything behind the line worth unfolding it for.
    private var hasDetail: Bool {
        !call.content.isEmpty || !call.locations.isEmpty || raw != nil
    }

    /// What the runtime sent, as it sent it. Every runtime describes its tools
    /// differently and none of that is ours to tidy.
    private var raw: String? {
        let interesting = call.rawInput ?? call.raw?["rawInput"] ?? call.rawOutput ?? call.raw
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

private struct StateLine: View {
    let state: AgentState
    let reason: EndedReason?

    var body: some View {
        Text(text)
            .font(.caption)
            // The one place a colour earns itself: something went wrong.
            .foregroundStyle(isFailure ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
    }

    private var isFailure: Bool {
        reason == .processDied || reason == .daemonGone
    }

    private var text: String {
        switch state {
        case .running: return "Working"
        case .waitingOnUser: return "Waiting on you"
        case .finished: return "Finished"
        case .stopped:
            switch reason {
            case .cancelled: return "You stopped it"
            case .processDied: return "The runtime crashed"
            case .daemonGone: return "Stopped when the daemon did"
            case .maxTokens: return "Ran out of room"
            case .maxTurnRequests: return "Hit its limit"
            case .refusal: return "Refused to carry on"
            case .unrecognised: return "Stopped for a reason we do not know"
            case .endTurn, nil: return "Stopped"
            }
        case .archived: return "Archived"
        }
    }
}
