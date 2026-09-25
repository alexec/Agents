import AgentsKitCore
import SwiftUI

/// One thing in the conversation.
///
/// No colour, except where something went wrong. No icons. What a line is comes from
/// what it says and from how it sits — the same rule the Mac's transcript follows, at
/// a width where there is less room to break it.
struct EntryView: View {
    let item: TranscriptItem

    var body: some View {
        switch item {
        case .entry(let entry):
            EntryRow(entry: entry)
        case .toolRun(let id, let calls):
            ToolRunRow(id: id, calls: calls)
        }
    }
}

private struct EntryRow: View {
    let entry: TranscriptEntry

    var body: some View {
        switch entry.kind {
        case .userMessage(let text, let blocks, let from):
            // The same rule as the Mac's: the app's one question is drawn as what it
            // is, and never in the person's bubble (FR-022).
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
            PlanView(plan: Plan(planID: nil,
                                entries: (raw["entries"]?.arrayValue ?? []).compactMap(PlanEntry.init(wire:))))

        case .planUpdated(let plan):
            PlanView(plan: plan)

        case .usageRecorded(let usage):
            if let line = Self.usageLine(usage) {
                Text(line).appText(.fine).foregroundStyle(.tertiary)
            }

        case .servedRequest(let request):
            Text(request.summary).appText(.fine).foregroundStyle(.tertiary)

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

        case .optionChanged(let id, let value):
            Text("\(id) is now \(value.stringValue ?? "changed")")
                .appText(.fine)
                .foregroundStyle(.secondary)

        case .stateChanged(let state, let reason):
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

    /// What a turn cost, where the runtime said. Nothing is worked out from a token
    /// count we were not given a price for.
    static func usageLine(_ usage: TurnUsage) -> String? {
        guard let cost = usage.cost else { return nil }
        return "\(usage.totalTokens.formatted()) tokens · "
            + cost.amount.money(in: cost.currency)
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

/// A run of tool calls: what it is doing now, and the rest a tap away.
private struct ToolRunRow: View {
    let id: UUID
    let calls: [ToolCall]
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if isExpanded {
                ForEach(Array(calls.enumerated()), id: \.offset) { _, call in
                    ToolCallLine(call: call)
                }
                Button("Show less") { withAnimation { isExpanded = false } }
                    .appText(.fine)
            } else {
                if let latest = calls.last { ToolCallLine(call: latest) }
                if calls.count > 1 {
                    Button("\(calls.count - 1) more") { withAnimation { isExpanded = true } }
                        .appText(.fine)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One tool call: the line the runtime wrote for a person to read, and nothing else
/// until it is asked for.
///
/// A turn can be a dozen of these, and on a phone unfolding every diff as it arrives
/// would bury the two sentences either side of them under a screen of scrolling.
private struct ToolCallLine: View {
    let call: ToolCall
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                guard hasDetail else { return }
                withAnimation(.easeOut(duration: 0.15)) { isExpanded.toggle() }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "chevron.right")
                        .appText(.fine)
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .opacity(hasDetail ? 1 : 0)
                        .frame(width: 8, alignment: .leading)
                    Text(call.line)
                        .appText(.supporting)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(!hasDetail)

            if isExpanded { detail }
        }
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(call.content.enumerated()), id: \.offset) { _, piece in
                view(for: piece)
            }
            if !call.locations.isEmpty {
                // Where it did its work, and now openable (FR-020a). Still not a
                // second file system: what opens is the change the agent made to that
                // file, out of this conversation, not a read of the Mac's disk.
                FlowOfNames(locations: call.locations)
            }
        }
        .padding(.leading, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func view(for piece: ToolCallContent) -> some View {
        switch piece {
        case .diff(let diff):
            DiffView(diff: diff)
        case .content(let block):
            BlocksView(blocks: [block])
                .appText(.supporting)
                .foregroundStyle(.secondary)
        case .terminal:
            // The terminal's output is streamed to the Mac's window, not to a phone.
            Text("Ran a command on your Mac")
                .appText(.fine)
                .foregroundStyle(.tertiary)
        case .unknown:
            // Kept in the record, and not guessed at here.
            Text("Something this version does not know how to show")
                .appText(.fine)
                .foregroundStyle(.tertiary)
        }
    }

    private var hasDetail: Bool {
        !call.content.isEmpty || !call.locations.isEmpty
    }
}

/// The chat is being picked back up by the Mac, and nobody typed for it.
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

    private var isFailure: Bool { reason == .processDied || reason == .daemonGone }

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
            // The same words as the window's copy of this switch, which is what
            // FR-027 asks for: an agent stopped by a limit reads the same on both.
            case .costLimit: return "Reached its cost limit"
            case .endTurn, nil: return "Stopped"
            }
        case .archived: return "Archived"
        }
    }
}

/// The files a tool call touched, each a way into what it did to that one.
///
/// A row of buttons rather than one joined line: a tool call can touch six files and
/// on a phone the sixth needs to be reachable without the reader guessing where one
/// name ends. Wrapped, because file names are long and a horizontal scroll inside a
/// vertical one is a trap.
private struct FlowOfNames: View {
    @Environment(RemoteModel.self) private var model
    let locations: [ToolCallLocation]

    var body: some View {
        WrappingHStack(spacing: 8) {
            ForEach(locations) { location in
                Button {
                    model.fileOnScreen = location.path
                } label: {
                    Text(location.fileName)
                        .appText(.fine)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .buttonStyle(.plain)
                // The accent, on purpose: this is a control that opens a diff, not a
                // state, and controls are drawn the way the system draws controls.
                // Out of `StateTint`'s scope (FR-006b); the consistency check
                // allow-lists this line by name.
                .foregroundStyle(Color.accentColor)
                .accessibilityLabel("Show what changed in \(location.fileName)")
            }
        }
    }
}

/// A row that wraps. SwiftUI has no such stack, and a `Layout` is the one honest way
/// to get one: a `LazyVGrid` with adaptive columns gives every name the width of the
/// longest, which on a list of `main.swift` and `DaemonCore+Dispatch.swift` is most of
/// the screen spent on white space.
private struct WrappingHStack: Layout {
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
