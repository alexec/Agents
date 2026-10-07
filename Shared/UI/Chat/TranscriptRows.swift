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

/// One turn, at the level it is drawn at (069).
///
/// Its outcome — the ask, the answers, the reply and how it went — is drawn at every
/// level. Between the ask and the outcome, one control opens the steps; it is the only
/// thing in a turn that does, so the reply's text can be selected like any other.
///
/// Equal when what it draws is: the closures are left out, because they are made again
/// on every pass of the chat and do the same thing for the same turn. Without this,
/// every streamed chunk drew every turn of the conversation again (#90).
struct TurnView: View, Equatable {
    let turn: ChatTurn
    /// The app's default, or what the person chose for this turn.
    let detail: TurnDetail
    /// A stored turn's own entries, once fetched.
    let fetched: [TranscriptItem]?
    /// Whether this is the turn still going.
    let isLive: Bool
    let toggle: () -> Void
    /// Fetch a stored turn's entries, for a turn drawn with its steps.
    let fetch: () async -> Void

    nonisolated static func == (a: TurnView, b: TurnView) -> Bool {
        a.turn == b.turn && a.detail == b.detail && a.fetched == b.fetched && a.isLive == b.isLive
    }

    var body: some View {
        // Once. Each of these used to fold the turn again (#285).
        let waiting = turn.isSummaryOnly && fetched == nil
        let items = turn.isSummaryOnly ? (fetched ?? []) : turn.items
        let parts = waiting ? nil : TurnParts(items, isLive: isLive)
        let outcome = parts?.outcome ?? turn.storedOutcome ?? []
        // Nil for a summary written before 069 (after the #58 cut-off), whose steps are not counted.
        let stepCount = parts?.stepCount ?? turn.storedStepCount
        let steps: [TranscriptItem] = {
            guard detail.showsSteps, parts != nil else { return [] }
            let shown = Set(outcome.map(\.id))
            return TurnParts.drawn(items, isLive: isLive)
                .filter { !shown.contains($0.id) && (detail == .details || !$0.isThought) }
        }()
        VStack(alignment: .leading, spacing: 14) {
            if let ask = turn.ask {
                TranscriptRow(item: ask)
            }
            if stepCount != 0 {
                StepsControl(count: stepCount, isOpen: detail.showsSteps, toggle: toggle)
            }
            if detail.showsSteps, stepCount != 0 {
                if waiting {
                    ProgressView().controlSize(.small)
                } else {
                    // In the turn's own margin: no rule and no indent (#148).
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(steps) { StepRow(item: $0, isOpen: detail == .details) }
                    }
                    ForEach(outcome) { StepRow(item: $0, isOpen: false) }
                }
            } else {
                // Under the control, where the steps would be: what it is doing now.
                if let live = parts?.live { LiveLine(item: live) }
                ForEach(outcome) { StepRow(item: $0, isOpen: false) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: detail.showsSteps) {
            if detail.showsSteps, waiting { await fetch() }
        }
    }
}

/// "12 steps", or "Hide steps": the one way into a turn's steps and back out.
private struct StepsControl: View {
    let count: Int?
    let isOpen: Bool
    let toggle: () -> Void
    @State private var isHovering = false

    private var words: String {
        if isOpen { return "Hide steps" }
        switch count {
        case nil: return "Show steps"
        case 1?: return "1 step"
        case let n?: return "\(n) steps"
        }
    }

    var body: some View {
        Button(action: toggle) {
            // The words alone, with no chevron in front of them (#148).
            Text(words)
                .appText(.fine)
                .foregroundStyle(isHovering ? .primary : .secondary)
                .padding(.horizontal, 8)
                #if os(iOS)
                .frame(minHeight: 32)
                #else
                .padding(.vertical, 3)
                #endif
                .background {
                    // A finger has no hover, so on the phone the edge is always there.
                    #if os(iOS)
                    Capsule().strokeBorder(.quaternary)
                    #else
                    Capsule().strokeBorder(.quaternary).opacity(isHovering ? 1 : 0)
                    #endif
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(isOpen ? "Hide this turn's steps" : "Show every step of this turn")
        .accessibilityLabel(words)
    }
}

/// A running turn's latest step, in one line, until the turn has its outcome.
private struct LiveLine: View {
    let item: TranscriptItem

    var body: some View {
        if case .toolRun(_, let calls) = item, let call = calls.last {
            Text(call.turnLine)
                .appText(.reading)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            StepRow(item: item, isOpen: false)
        }
    }
}

/// One item of a turn: a call a line of its own, anything else as it is drawn.
private struct StepRow: View {
    let item: TranscriptItem
    /// Every call open from the start, at Details.
    let isOpen: Bool

    var body: some View {
        switch item {
        case .toolRun(_, let calls):
            VStack(alignment: .leading, spacing: isOpen ? 12 : 4) {
                ForEach(Array(calls.enumerated()), id: \.offset) { _, call in
                    ToolCallLine(call: call, lineText: call.turnLine, isOpen: isOpen, brightensOnHover: true)
                }
            }
        case .entry(let entry):
            if case .toolCall(let call) = entry.kind {
                ToolCallLine(call: call, lineText: call.turnLine, isOpen: isOpen, brightensOnHover: true)
            } else {
                EntryRow(entry: entry)
            }
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
                    Text("Agents asked").appText(.reading).foregroundStyle(.tertiary)
                    BlocksView(blocks: blocks.isEmpty ? [.text(text)] : blocks)
                        .appText(.reading)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                // Theirs, so at the right, as wide as its words and no wider.
                BlocksView(blocks: blocks.isEmpty ? [.text(text)] : blocks)
                    .environment(\.textFillsWidth, false)
                    .appText(.reading)
                    .padding(12)
                    .paperWell(in: RoundedRectangle(cornerRadius: 12))
                    .padding(.leading, 60)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }

        case .agentMessage(_, let text, let blocks):
            BlocksView(blocks: blocks.isEmpty ? [.text(text)] : blocks)
                .appText(.reading)

        case .agentThought(_, let text):
            Text(text)
                .appText(.reading)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

        case .toolCall(let call), .toolCallUpdate(let call):
            // Reached only when something splits a run; a run is drawn by ToolRunRow.
            Text(call.line).appText(.reading).foregroundStyle(.secondary)

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
            Text("Asked: \(request.title)").appText(.reading).foregroundStyle(.secondary)

        case .elicitationAnswered(_, let summary, let answers):
            if answers.isEmpty {
                Text(summary).appText(.reading).foregroundStyle(.secondary)
            } else {
                // What they said is theirs, so it sits in their bubble, each answer
                // under the question it answers: the card that asked is gone.
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(answers.enumerated()), id: \.offset) { _, answer in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(answer.question).appText(.reading).foregroundStyle(.secondary)
                            Text(answer.answer).appText(.reading).textSelection(.enabled)
                        }
                    }
                }
                .padding(12)
                .paperWell(in: RoundedRectangle(cornerRadius: 12))
                .frame(maxWidth: .infinity, alignment: .leading)
            }

        case .compaction(let status, let summary):
            VStack(alignment: .leading, spacing: 6) {
                Text(status == "completed" ? "Made room by summarising the conversation so far"
                                           : "Summarising the conversation so far…")
                    .appText(.reading)
                    .foregroundStyle(.secondary)
                if !summary.isEmpty {
                    BlocksView(blocks: summary).foregroundStyle(.secondary)
                }
            }

        case .notice(let notice):
            NoticeLine(notice: notice)

        case .permissionAsked(let request):
            Text("Asked: \(request.toolCall.title)")
                .appText(.reading)
                .foregroundStyle(.secondary)

        case .permissionAnswered(let optionID, let name):
            Text("You chose \(name ?? optionID)")
                .appText(.reading)
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
            Text(text).appText(.reading).foregroundStyle(.secondary)

        case .poolSwitch(let record):
            SwitchNote(record: record)

        case .sandboxFailure(let record):
            SandboxFailureCard(record: record)

        case .settingsChanged(let record):
            Text("Changed what it carried on with: "
                 + record.carried.compactMap { s in s.to?.stringValue.map { "\(s.name) \($0)" } }.joined(separator: ", "))
                .appText(.reading).foregroundStyle(.secondary)

        case .handoff(let markdown, let characters):
            HandoffLine(markdown: markdown, characters: characters)
        case .background(let item):
            BackgroundEntryLine(item: item)

        case .appView(let call):
            AppViewRow(call: call)

        case .unrecognised:
            // Written by a newer version of this app. Kept in the record, skipped here.
            EmptyView()
        }
    }
}

/// Something the runtime wanted said beside the reply: a limit coming up, a model it
/// fell back to. Drawn like the app's own notes, because it is not the agent talking.
/// An error is the one worth a colour; a warning gets its title in medium weight.
private struct NoticeLine: View {
    let notice: SessionNotice

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(notice.title)
                .appText(.reading)
                .fontWeight(notice.isError || notice.isWarning ? .medium : .regular)
                .foregroundStyle((notice.isError ? StateTint.failure : .none).style(or: .secondary))
            if let detail = notice.detail {
                Text(detail)
                    .appText(.reading)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
                .appText(.reading).fontWeight(.medium)
                .foregroundStyle((report.outcome.needsAPerson ? StateTint.attention : .none)
                                    .style(or: .secondary))
            Text(report.message)
                .appText(.reading)
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
    /// A turn is running and its runtime takes words mid-turn (`_session/steering`).
    var canSendNow = false

    var body: some View {
        // Held while anything is on its way to this agent; this one, said (#87).
        let acting = actions.acting(agentID)
        let going = acting == .sendNow(prompt.id)
        // The person's bubble (TranscriptRow's .userMessage), dashed and dimmed: at the
        // right, as wide as its words, with what can be done to it underneath, so the
        // buttons never push it off the edge (#95).
        VStack(alignment: .trailing, spacing: 2) {
            BlocksView(blocks: prompt.blocks)
                .environment(\.textFillsWidth, false)
                .appText(.reading)
                .foregroundStyle(.secondary)
                .padding(12)
                .paperWell(in: RoundedRectangle(cornerRadius: 12))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(.quaternary, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                }
                // No title says it is waiting, so the label does; one element, so the
                // label never sits over a child's (stacked labels crash AppKit).
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Queued: \(prompt.text)")
                .accessibilityAction(named: "Send now") {
                    guard canSendNow, acting == nil else { return }
                    Task { await actions.sendNow(prompt, agentID) }
                }
                .accessibilityAction(named: "Remove") {
                    guard !going else { return }
                    Task { await actions.unqueue(prompt, agentID) }
                }

            // A step down from the words, so the row under the bubble stays quiet.
            HStack(spacing: 12) {
                if canSendNow {
                    Button {
                        Task { await actions.sendNow(prompt, agentID) }
                    } label: {
                        Group {
                            if going {
                                Telling(host: actions.recipient(agentID), doing: acting?.doing)
                            } else {
                                Label("Send now", systemImage: "arrow.up")
                                    .appText(.supporting)
                            }
                        }
                        #if os(iOS)
                        .frame(minHeight: 44)
                        .contentShape(.rect)
                        #endif
                    }
                    .buttonStyle(.borderless)
                    // The one going stays bright, as on the answer cards (#86); the
                    // model refuses a second press of it.
                    .disabled(acting != nil && !going)
                    .help("Send this into the turn that is running, without waiting for it to end")
                }

                Button {
                    Task { await actions.unqueue(prompt, agentID) }
                } label: {
                    Image(systemName: "xmark")
                        .appText(.supporting)
                        .frame(width: 18, height: 18)
                        #if os(iOS)
                        // A finger, not a pointer: the glyph stays small and the target does not.
                        .frame(width: 44, height: 44)
                        .contentShape(.rect)
                        #endif
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.tertiary)
                .disabled(going)
                .help("Do not send this")
                .accessibilityLabel("Remove queued prompt")
            }
        }
        .padding(.leading, 60)
        .frame(maxWidth: .infinity, alignment: .trailing)
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
    @Environment(\.backgroundWork) private var background
    let call: ToolCall
    /// What the line says, where not the runtime's own line: a turn's description.
    var lineText: String? = nil
    /// Open from the start and for good: a verbose turn, where the click belongs to
    /// the turn.
    var isOpen = false
    /// What a click does instead of opening the call, where the line is standing in
    /// for a whole folded run.
    var onClick: (() -> Void)? = nil
    /// Brighter under the pointer, as a turn's step is (069): the step is a line of
    /// text like the rest of the turn's margin, with no chevron in front of it (#112).
    var brightensOnHover = false
    @State private var isExpanded = false
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if isOpen { line } else { summary }
            if isExpanded || isOpen { detail }
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
            .help(isExpanded ? "Hide the argument and the return" : "Show the argument and the return")
            .accessibilityHint(isExpanded ? "Hides the argument and the return" : "Shows the argument and the return")
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
        Text((lineText ?? call.line) + runsOn)
            .appText(.reading)
            .foregroundStyle(isHovering ? .primary : .secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
            .onHover { isHovering = brightensOnHover && $0 }
    }

    /// " · running in the background", while what this call started still runs (057).
    /// The call itself came back at once; without this it reads as done.
    private var runsOn: String {
        guard let id = call.toolCallID,
              background.contains(where: { $0.toolCallID == id && $0.isRunning }) else { return "" }
        return " · running in the background"
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
                                .appText(.reading)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .linkStyle()
                        .accessibilityLabel("Open \(location.fileName)")
                    }
                }
            }

            if let argument = call.rawInput {
                exchanged("Argument", Self.pretty(argument))
            }
            if let returned = call.rawOutput {
                exchanged("Return", Self.pretty(returned))
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
                        .appText(.reading)
                        .help("See this edit among everything the agent changed")
                }
            }
        case .content(let block):
            BlocksView(blocks: [block])
                .appText(.reading)
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

    /// The argument or the return, under a word that says which. A runtime's own
    /// bytes — Grok sends a tool's output as a list of numbers — are read back into
    /// text here, because a page of integers is not what came back.
    private func exchanged(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).appText(.reading).foregroundStyle(.tertiary)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text)
                    .appText(.code)
                    .textSelection(.enabled)
                    .padding(10)
            }
            .frame(maxHeight: 260)
            .paperWell(in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private static func pretty(_ value: JSONValue) -> String {
        let readable = value.readingByteArraysAsText()
        if let text = readable.stringValue { return text }
        guard let data = try? JSONEncoder.pretty.encode(readable) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}

private extension JSONValue {
    /// A list of bytes, the way some runtimes send a tool's output, read as text.
    /// Anything that is not a list of bytes is left as it arrived.
    func readingByteArraysAsText() -> JSONValue {
        switch self {
        case .array(let values):
            if let text = Self.text(ofBytes: values) { return .string(text) }
            return .array(values.map { $0.readingByteArraysAsText() })
        case .object(let fields):
            return .object(fields.mapValues { $0.readingByteArraysAsText() })
        default:
            return self
        }
    }

    private static func text(ofBytes values: [JSONValue]) -> String? {
        let bytes = values.compactMap(\.intValue)
        guard bytes.count == values.count, !bytes.isEmpty,
              bytes.allSatisfy({ (0...255).contains($0) }) else { return nil }
        let raw = bytes.map { UInt8(truncatingIfNeeded: $0) }
        guard let text = String(bytes: raw, encoding: .utf8) else { return nil }
        let printable = text.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) || $0 == "\n" || $0 == "\t" || $0 == "\r"
        }
        guard printable.count * 10 >= text.unicodeScalars.count * 9 else { return nil }
        return text
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
/// sidebar row shows, turning in step with it (`SyncedSpinner`), at the foot of the
/// conversation, so the chat itself moves while nothing else on it does. Live rather
/// than recorded — it is there exactly as long as the wait is, and it rides the end of
/// the transcript as the reply arrives.
struct WorkingLine: View {
    var body: some View {
        SyncedSpinner(diameter: 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 2)
            .accessibilityLabel("Working")
    }
}

/// The chat is being picked back up by the daemon, and nobody typed for it.
struct ComingBackLine: View {
    var body: some View {
        Label(AgentsModel.comingBackDescription, systemImage: AgentsModel.comingBackSymbol)
            .appText(.reading)
            .foregroundStyle(.secondary)
    }
}

private struct StateLine: View {
    let state: AgentState
    let reason: EndedReason?

    var body: some View {
        Text(text)
            .appText(.reading)
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
        case .queued: return HelperLimit.queuedLabel(position: nil)
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
            case .runtimeError: return "The runtime reported an error"
            case .allowanceSpent: return "Its allowance ran out"
            case .rateLimited: return "Rate limited, and still limited after retrying"
            case .daemonGone: return "Stopped when the daemon did"
            case .maxTokens: return "Ran out of room"
            case .maxTurnRequests: return "Hit its limit"
            case .refusal: return "Refused to carry on"
            case .unrecognised: return "Stopped for a reason we do not know"
            case .costLimit: return "Reached its cost limit"
            case .sandboxFailed: return "Its sandbox could not start"
            case .imported: return "Imported from another set-up, so not run here"
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
