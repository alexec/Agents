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
                    Text("Agents asked").font(.caption).foregroundStyle(.tertiary)
                    BlocksView(blocks: blocks.isEmpty ? [.text(text)] : blocks)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                BlocksView(blocks: blocks.isEmpty ? [.text(text)] : blocks)
                    .padding(12)
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

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
            PlanView(plan: Plan(planID: nil,
                                entries: (raw["entries"]?.arrayValue ?? []).compactMap(PlanEntry.init(wire:))))

        case .planUpdated(let plan):
            PlanView(plan: plan)

        case .usageRecorded(let usage):
            if let line = Self.usageLine(usage) {
                Text(line).font(.caption).foregroundStyle(.tertiary)
            }

        case .servedRequest(let request):
            Text(request.summary).font(.caption).foregroundStyle(.tertiary)

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

        case .workReported(let report):
            WorkReportLine(report: report)

        case .runtimeNote(let text):
            Text(text).font(.caption).foregroundStyle(.secondary)

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
            + cost.amount.formatted(.currency(code: cost.currency))
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
                .font(.callout.weight(.medium))
                .foregroundStyle(report.outcome.needsAPerson
                                 ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
            Text(report.message)
                .font(.callout)
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
                    .font(.caption)
            } else {
                if let latest = calls.last { ToolCallLine(call: latest) }
                if calls.count > 1 {
                    Button("\(calls.count - 1) more") { withAnimation { isExpanded = true } }
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
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .opacity(hasDetail ? 1 : 0)
                        .frame(width: 8, alignment: .leading)
                    Text(call.title)
                        .font(.callout)
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
                // Where it did its work. Named, not opened: the file is on the Mac,
                // and a remote that pretended otherwise would be a second file system.
                Text(call.locations.map(\.fileName).joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
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
                .font(.callout)
                .foregroundStyle(.secondary)
        case .terminal:
            // The terminal's output is streamed to the Mac's window, not to a phone.
            Text("Ran a command on your Mac")
                .font(.caption)
                .foregroundStyle(.tertiary)
        case .unknown:
            // Kept in the record, and not guessed at here.
            Text("Something this version does not know how to show")
                .font(.caption)
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
            .font(.caption)
            .foregroundStyle(.secondary)
    }
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

    private var isFailure: Bool { reason == .processDied || reason == .daemonGone }

    private var text: String {
        switch state {
        case .running: return "Working"
        case .waitingOnUser: return "Waiting on you"
        // Never "Complete": that word is now reserved for an agent that said `done`
        // itself, and a turn handing itself back says nothing about the work (FR-012).
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
            // The same words as the window's copy of this switch, which is what
            // FR-027 asks for: an agent stopped by a limit reads the same on both.
            case .costLimit: return "Reached its cost limit"
            case .endTurn, nil: return "Stopped"
            }
        case .archived: return "Archived"
        }
    }
}
