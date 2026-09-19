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

    var body: some View {
        ScrollViewReader { scroller in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if model.transcriptHasMore {
                        Button("Show earlier") { Task { await model.loadEarlier() } }
                            .buttonStyle(.link)
                    }
                    ForEach(TranscriptEntry.display(model.entries)) { item in
                        row(for: item).id(item.id)
                    }
                    Color.clear.frame(height: 1).id(bottom)
                }
                // Lines up with the prompt bar below it: one left edge down the pane.
                .padding(.horizontal, 144)
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentMargins(.bottom, bottomInset, for: .scrollContent)
            .onChange(of: model.entries.count) {
                withAnimation(.easeOut(duration: 0.15)) { scroller.scrollTo(bottom, anchor: .bottom) }
            }
            .onChange(of: model.selection) { expandedRuns = [] }
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

/// One tool call: what it is doing, what it produced, and the raw detail only when
/// asked for.
///
/// Copilot and Grok send a structured diff for an edit; the Claude adapter shells out
/// and sends console text. Both are drawn as what they are. Nothing is invented for the
/// runtime that sends neither.
private struct ToolCallLine: View {
    @Environment(AppModel.self) private var model
    let call: ToolCall
    @State private var isShowingDetail = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(call.title)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if detail != nil {
                    Button(isShowingDetail ? "Less" : "More") { isShowingDetail.toggle() }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }

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

            if isShowingDetail, let detail {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(detail)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .padding(10)
                }
                .frame(maxHeight: 260)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
            }
        }
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

    /// What the runtime sent, as it sent it. Every runtime describes its tools
    /// differently and none of that is ours to tidy.
    private var detail: String? {
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
