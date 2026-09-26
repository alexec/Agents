import AgentsKitCore
import SwiftUI

/// What the agent has said and done, one line at a time, the same on every screen (033).
///
/// No colour: the only thing worth a colour here is something going wrong. No icons
/// either. What a line is comes from what it says and from how it sits.
///
/// These were two copies, the Mac's and the phone's, and in less than a month the phone's
/// had grown a chevron and an "11 more" button the Mac never had, and lost the raw input
/// the Mac shows. One copy cannot drift. What differs by app comes in as `ChatActions`.
struct TranscriptRow: View {
    let item: TranscriptItem
    /// Whether this run of tool calls is unfolded. Held by the chat, not here, so a
    /// change of conversation folds every run again.
    var isExpanded = false
    var toggle: () -> Void = {}

    var body: some View {
        switch item {
        case .entry(let entry):
            EntryRow(entry: entry)
        case .toolRun(_, let calls):
            ToolRunRow(calls: calls, isExpanded: isExpanded, toggle: toggle)
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
struct QueuedPromptRow: View {
    @Environment(\.chatActions) private var actions
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
                Task { await actions.unqueue(prompt, agentID) }
            } label: {
                Image(systemName: "xmark")
                    .appText(.fine)
                    .frame(width: 18, height: 18)
                    #if os(iOS)
                    // A finger, not a pointer: the glyph stays small and the target does not.
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
                    #endif
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.tertiary)
            .help("Do not send this")
            .accessibilityLabel("Remove queued prompt")
        }
    }
}

/// A run of tool calls: what it is doing now, and the rest a tap away.
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
    @Environment(\.chatActions) private var actions
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
                .accessibilityHint("Shows every call in this run")
        } else if hasDetail {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { isExpanded.toggle() }
            } label: {
                line
            }
            .buttonStyle(.plain)
            .help(isExpanded ? "Hide what it did" : "Show what it did")
            .accessibilityHint(isExpanded ? "Hides what it did" : "Shows what it did")
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
                // Where it did its work, each a way in. Wrapped, because file names are
                // long, and on a phone the sixth has to be reachable without guessing
                // where the fifth ended.
                WrappingHStack(spacing: 10) {
                    ForEach(call.locations) { location in
                        Button {
                            actions.open(location)
                        } label: {
                            Text(location.line.map { "\(location.fileName):\($0)" } ?? location.fileName)
                                .appText(.fine)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .linkStyle()
                        .accessibilityLabel("Open \(location.fileName)")
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

    /// Claude and Copilot send a structured diff for an edit; Grok sends none. What is
    /// sent is drawn as what it is. Nothing is invented for the runtime that sends
    /// nothing.
    @ViewBuilder
    private func view(for piece: ToolCallContent) -> some View {
        switch piece {
        case .diff(let diff):
            VStack(alignment: .trailing, spacing: 4) {
                DiffView(diff: diff)
                // A link under the edit rather than the edit as a button: the lines
                // stay selectable, and the way in is said in words.
                if let showEdit = actions.showEdit {
                    Button("Show in Changes") { showEdit(diff, call.toolCallID) }
                        .linkStyle()
                        .appText(.fine)
                        .help("See this edit among everything the agent changed")
                }
            }
        case .content(let block):
            BlocksView(blocks: [block])
                .appText(.supporting)
                .foregroundStyle(.secondary)
        case .terminal(let id):
            TerminalOutputView(text: actions.terminalOutput(id))
        case .unknown(let raw):
            // Kept rather than dropped: shown as what the runtime sent.
            Text(Self.pretty(raw))
                .appText(.code)
                .foregroundStyle(.tertiary)
                .lineLimit(6)
        }
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
struct WorkingLine: View {
    var body: some View {
        ProgressView()
            .controlSize(.small)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 2)
            .accessibilityLabel("Working")
    }
}

/// The chat is being picked back up by the daemon, and nobody typed for it.
struct ComingBackLine: View {
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
            case .signInRefused: return "Its sign-in was refused"
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

extension View {
    /// A control that goes somewhere, drawn the way each system draws one. The accent,
    /// on purpose: this is a control, not a state, and out of `StateTint`'s scope.
    @ViewBuilder
    func linkStyle() -> some View {
        #if os(macOS)
        buttonStyle(.link)
        #else
        buttonStyle(.plain).foregroundStyle(Color.accentColor)
        #endif
    }
}

/// A row that wraps. SwiftUI has no such stack, and a `Layout` is the one honest way
/// to get one: a `LazyVGrid` with adaptive columns gives every name the width of the
/// longest, which on a list of `main.swift` and `DaemonCore+Dispatch.swift` is most of
/// the width spent on white space.
struct WrappingHStack: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = arrange(subviews: subviews, in: width)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews: subviews, in: bounds.width) {
            var x = bounds.minX
            for item in row.items {
                subviews[item.index].place(at: CGPoint(x: x, y: y),
                                           anchor: .topLeading,
                                           proposal: ProposedViewSize(item.size))
                x += item.size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var items: [(index: Int, size: CGSize)] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(subviews: Subviews, in width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
            let needed = row.items.isEmpty ? size.width : row.width + spacing + size.width
            if needed > width, !row.items.isEmpty {
                rows.append(row)
                row = Row()
            }
            row.width = row.items.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.items.append((index, size))
        }
        if !row.items.isEmpty { rows.append(row) }
        return rows
    }
}
