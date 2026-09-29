import AgentsKitCore
import SwiftUI

/// What an agent has running in the background, over the prompt (057, frame A): one row
/// per shell or subagent while it runs, a shell with Stop, a subagent with Steps.
///
/// Where 036's leases and 042's wait already sit, and like them untinted: something
/// running is neither a person being needed nor anything broken. Only running ones are
/// here; one that ends leaves, and the chat keeps the line saying how.
///
/// One view for both apps. The phone draws `BackgroundLine` instead, because two rows
/// over a phone's prompt are a fifth of its screen (frame E); an iPad draws this.
struct BackgroundBlock: View {
    let items: [BackgroundItem]
    var actions: BackgroundActions

    private var running: [BackgroundItem] { items.filter(\.isRunning) }

    var body: some View {
        if !running.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text("In the background · \(running.count)")
                    .appText(.fine)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 4)
                ForEach(running) { item in
                    BackgroundItemRow(item: item, actions: actions)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .paperRaised(in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

/// What a row can do, which differs by app. Nil is not offered.
struct BackgroundActions {
    /// Stop a task. Offered only where the runtime says Stop works on it.
    var stop: (@MainActor (BackgroundItem) async -> Void)?
    /// Open a subagent's own steps: the Mac's Background pane, the phone's sheet.
    var steps: (@MainActor (BackgroundItem) -> Void)?
    /// Open a task's output file.
    var output: (@MainActor (BackgroundItem) -> Void)?
}

/// One running thing: what it is, its name, what it runs or was asked, how long, and
/// its one or two buttons.
struct BackgroundItemRow: View {
    let item: BackgroundItem
    let actions: BackgroundActions
    /// On the phone's sheet the detail goes under the name rather than beside it.
    var stacked = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: BackgroundWords.symbol(item))
                .appText(.fine)
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .accessibilityHidden(true)
            if stacked {
                VStack(alignment: .leading, spacing: 2) {
                    name
                    HStack(spacing: 6) { detail; age }
                }
            } else {
                name
                detail
                age
            }
            Spacer(minLength: 0)
            buttons
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
        .opacity(item.isStopping ? 0.55 : 1)
    }

    private var name: some View {
        Text(item.name)
            .appText(.supporting)
            .fontWeight(.medium)
            // An ended one stays listed so its steps and output can still be read, and
            // must not look like one still running (walked 2026-09-26: a stopped shell
            // in the pane read exactly like a live one).
            .foregroundStyle(item.isRunning ? .primary : .secondary)
            .lineLimit(1)
            .help(item.command ?? "\(BackgroundWords.noun(item)): \(item.name)")
    }

    @ViewBuilder
    private var detail: some View {
        // A shell's command, or what a subagent was asked. Not repeated when the
        // runtime's name for it is the same words.
        if let detail = item.detail, detail != item.name {
            Text(detail)
                .appText(item.isShell ? .code : .fine)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(detail)
        }
    }

    private var age: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(item.isStopping ? "Stopping…"
                 : BackgroundWords.ended(item).map { "\($0) · \(BackgroundWords.age(item))" }
                 ?? BackgroundWords.age(item, now: context.date))
                .appText(.fine)
                .monospacedDigit()
                .foregroundStyle(.tertiary)
        }
        .fixedSize()
    }

    @ViewBuilder
    private var buttons: some View {
        if item.outputFilePath != nil, let output = actions.output {
            Button("Output") { output(item) }
                .buttonStyle(.paper)
                .appText(.fine)
                .help(item.isRunning ? "Open what it has printed so far" : "Open what it printed")
        }
        if item.kind == .subagent, let steps = actions.steps {
            Button("Steps") { steps(item) }
                .buttonStyle(.paper)
                .appText(.fine)
                .help(item.isRunning ? "See what this subagent is doing" : "See what this subagent did")
        }
        if !item.isRunning {
            // Ended: nothing to stop, so no Stop, not even a greyed one.
            EmptyView()
        } else if item.canStop, let stop = actions.stop {
            Button("Stop") { Task { await stop(item) } }
                .buttonStyle(.paper)
                .appText(.fine)
                .disabled(!item.offersStop)
                .help("Stop \(item.name), and nothing else the agent is doing")
                .accessibilityLabel("Stop \(item.name)")
        } else if item.kind == .subagent {
            // Said, not hidden: no runtime can stop a subagent on its own, and the
            // person looking for its Stop should learn where it is.
            Text("stops with the agent")
                .appText(.fine)
                .foregroundStyle(.tertiary)
                .help("Neither Claude nor Codex can stop one subagent alone. Stop the agent to stop it.")
        }
    }
}

/// The phone's form (frame E): one line over the prompt, "2 in the background ›", which
/// opens the list in a sheet with Stop on each shell.
struct BackgroundLine: View {
    let items: [BackgroundItem]
    var actions: BackgroundActions
    @State private var isShowingList = false

    private var running: [BackgroundItem] { items.filter(\.isRunning) }

    var body: some View {
        if !running.isEmpty {
            Button {
                isShowingList = true
            } label: {
                Label("\(running.count) in the background", systemImage: "chevron.right")
                    .labelStyle(TrailingIcon())
                    .appText(.fine)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .paperRaised(in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(BackgroundWords.mark(running) ?? "")
            .accessibilityHint("Shows what is running, with Stop")
            .sheet(isPresented: $isShowingList) {
                NavigationStack {
                    List {
                        ForEach(running) { item in
                            BackgroundItemRow(item: item, actions: sheetActions, stacked: true)
                        }
                    }
                    .navigationTitle("In the background")
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { isShowingList = false }
                        }
                    }
                }
                .presentationDetents([.medium, .large])
                .paperSheet()
            }
            // The last one ending takes the sheet with it rather than leaving it empty.
            .onChange(of: running.isEmpty) { _, empty in if empty { isShowingList = false } }
        }
    }

    /// Opening steps from the sheet closes it first, so the steps are not under it.
    private var sheetActions: BackgroundActions {
        var actions = actions
        if let steps = actions.steps {
            actions.steps = { item in
                isShowingList = false
                steps(item)
            }
        }
        return actions
    }
}

private struct TrailingIcon: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.title
            configuration.icon.imageScale(.small)
        }
    }
}

/// The line the chat keeps for background work (057): a subagent starting, with Steps,
/// and anything ending, with how.
///
/// A task starting from a tool call is not drawn: the call is already on the page and
/// says what was run. Its ending is, because nothing else would say so.
struct BackgroundEntryLine: View {
    @Environment(\.chatActions) private var actions
    let item: BackgroundItem

    var body: some View {
        HStack(spacing: 8) {
            Text(line)
                .appText(.reading)
                .foregroundStyle((item.state == .failed ? StateTint.failure : .none).style(or: .secondary))
            if item.kind == .subagent, let steps = actions.subagentSteps {
                Button("Steps") { steps(item.id) }
                    .linkStyle()
                    .appText(.reading)
                    .help("See what this subagent did")
            }
            if item.outputFilePath != nil, !item.isRunning, let output = actions.backgroundOutput {
                Button("Output") { output(item) }
                    .linkStyle()
                    .appText(.reading)
                    .help("Open what it printed")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var line: String {
        if item.isRunning {
            return item.kind == .subagent
                ? "Started subagent “\(item.name)” in the background"
                : "Started “\(item.name)” in the background"
        }
        return BackgroundWords.ending(item)
    }
}

/// One subagent: who it is, what it was asked, and what it did (057, frame C). The
/// Mac's Background pane and the phone's sheet.
struct SubagentStepsView: View {
    let item: BackgroundItem
    let entries: [TranscriptEntry]
    /// The session's thinking setting. The phone has no View menu and keeps showing it.
    var showsThinking = true
    /// Back to the list, where there is one to go back to: the Mac's pane.
    var back: (() -> Void)?
    @State private var expanded: Set<UUID> = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let back {
                    Button(action: back) {
                        Label("Everything in the background", systemImage: "chevron.left")
                    }
                    .linkStyle()
                    .appText(.fine)
                }

                Text(item.name).appText(.reading).fontWeight(.semibold)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(status(at: context.date))
                        .appText(.fine)
                        .foregroundStyle(.secondary)
                }
                if let asked = item.detail {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Asked to").appText(.fine).foregroundStyle(.tertiary)
                        Text(asked).appText(.supporting).textSelection(.enabled)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .paperWell(in: RoundedRectangle(cornerRadius: 8))
                }
                let steps = TranscriptEntry.display(entries, subagent: item.id)
                let shown = showsThinking ? steps : steps.omittingThoughts()
                if steps.isEmpty {
                    Text(item.isRunning ? "Nothing yet. Its steps appear here as it takes them."
                                        : "Its steps are further back in the conversation than is loaded.")
                        .appText(.fine)
                        .foregroundStyle(.tertiary)
                }
                ForEach(shown) { step in
                    TranscriptRow(item: step, isExpanded: expanded.contains(step.id)) {
                        if expanded.contains(step.id) { expanded.remove(step.id) } else { expanded.insert(step.id) }
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func status(at now: Date) -> String {
        let age = BackgroundWords.age(item, now: now)
        if item.isRunning { return "Subagent · running \(age) · stops with the agent" }
        return "\(BackgroundWords.ending(item)) · \(age)"
    }
}
