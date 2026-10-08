import AgentsKitCore
import SwiftUI

/// One workflow, opened up.
///
/// The reason this page exists is the prompt. An agent can write a workflow into a
/// project without anybody's approval — that is what `manage_workflows` is for — and
/// until there was somewhere to read one, the prompt was the single part of a standing
/// arrangement that nobody could see without leaving the app for an editor.
///
/// It is laid out as the prompt bar is, on purpose: the file where the bar has the
/// folder, the runtime top right, the prompt in the middle where the words go, and
/// under it the permission mode on the left and the model on the right. A workflow is
/// a prompt that sends itself, and its page should read as the thing it is. Below the
/// form, the agents it has run — three at a time, because there is no end to them.
///
/// Nothing on this page edits the file's triggers or its prompt. Those are the
/// author's, and an app that quietly rewrote the body of a file in somebody's
/// repository would be a worse thing than one that made you open an editor. What can
/// be changed from here is how much the workflow is allowed to do, and which
/// computers run it.
///
/// Every workflow opens, including the ones that cannot run: archived, over a ceiling,
/// waiting on a trigger this version does not know, and unreadable. The unreadable one
/// is the most important of them — it is the one most likely to need looking at, and a
/// row you cannot open is a row that can only tell you that something is wrong.
struct WorkflowPage: View {
    @Environment(AppModel.self) private var model
    /// `Workflow.id`, not the workflow itself: the file on disk is the truth, and
    /// holding a copy would leave this page showing what the file used to say.
    let workflowID: Workflow.ID

    /// The file's own text, read only when the workflow cannot be parsed.
    @State private var rawText: String?
    /// What the workflow's runtime last advertised for this project, out of the
    /// daemon's memory. Nil until asked; empty when it has nothing, which is an answer
    /// of its own and is drawn as one.
    @State private var remembered: [ConfigOption]?
    /// How many of its runs are on show. Three to begin with, and more on request.
    @State private var shownRuns = Self.runsAtFirst
    /// The workflow whose archived runs this page brought in, so leaving it — or
    /// opening another in this same view — lets those go (#285). A bigger page of the
    /// same workflow is not a leaving.
    @State private var runsHeld: RunsHeld?

    private static let runsAtFirst = 3
    private static let runsPerMore = 6

    private var summary: WorkflowSummary? {
        model.workflows(in: model.selectedProject).first { $0.id == workflowID }
    }

    var body: some View {
        ScrollView {
            if let summary {
                content(summary)
            } else {
                // The file went while it was open — deleted, renamed, or its project
                // closed. Saying so and going back beats a page about a workflow that
                // is not there, which a reader would take for a failure of the app.
                ContentUnavailableView("This workflow is no longer there",
                                       systemImage: "clock.badge.questionmark",
                                       description: Text("Its file has been removed or renamed."))
                    .padding(.top, 60)
            }
        }
        .navigationTitle(summary?.workflow.name ?? "Workflow")
        // Only once it has actually gone, and not while the list is still being loaded
        // — going back during the first draw would take the reader out of a page they
        // had only just opened.
        .onChange(of: summary == nil) { _, gone in
            guard gone, !model.workflows(in: model.selectedProject).isEmpty else { return }
            model.openWorkflow = nil
        }
        .onChange(of: workflowID) { shownRuns = Self.runsAtFirst }
        // Its runs, archived ones too, asked of the host: the window holds only the live
        // agents (#165). One more than shown, so Show more knows there is more.
        .task(id: RunsWanted(workflowID: workflowID, shown: shownRuns)) {
            guard let workflow = summary?.workflow else { return }
            let host = model.selectedProjectHost
            let next = RunsHeld(workflowID: workflow.workflowID, folder: workflow.folder, host: host)
            if let held = runsHeld, held.workflowID != next.workflowID || held.folder != next.folder
                || held.host != next.host {
                model.letGoOfRuns(of: held.workflowID, in: held.folder, on: held.host)
            }
            runsHeld = next
            await model.loadRuns(of: workflow.workflowID, in: workflow.folder,
                                 on: host, limit: shownRuns + 1)
        }
        .onDisappear {
            guard let held = runsHeld else { return }
            runsHeld = nil
            Task { @MainActor in
                model.letGoOfRuns(of: held.workflowID, in: held.folder, on: held.host)
            }
        }
    }

    /// Which workflow's runs this page is responsible for. The number on show is not
    /// part of it: Show more asks for a longer page of the same runs.
    private struct RunsHeld: Equatable {
        var workflowID: String
        var folder: URL
        var host: HostID
    }

    private struct RunsWanted: Hashable {
        var workflowID: Workflow.ID
        var shown: Int
    }

    @ViewBuilder
    private func content(_ summary: WorkflowSummary) -> some View {
        let workflow = summary.workflow
        VStack(alignment: .leading, spacing: 22) {
            heading(summary)
            // The page answers four questions in this order (#142): is it running and
            // why not, what it does, when it runs, and what it has done.
            status(summary)
            if workflow.problem != nil {
                broken(workflow)
            }
            form(summary)
            triggers(summary)
            hostsSection(summary)
            unknownKeys(workflow)
            history(summary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // The column the transcript, the prompt bar and the project page all use, so
        // this reads as another page of the same document rather than a panel.
        .chatColumn()
        .padding(.top, 28)
        .padding(.bottom, 40)
    }

    // MARK: The title line

    /// The name and what it is, in the row's words, and on the right the things you do
    /// to a workflow. What is happening to it is the status card's (#142).
    ///
    /// Deliberately the same sentence as the row: this page is the row opened up, not
    /// a second description of the same workflow that could come to disagree with it.
    private func heading(_ summary: WorkflowSummary) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(summary.workflow.name)
                    .appText(.title).fontWeight(.semibold)
                    .fixedSize(horizontal: false, vertical: true)
                // Not when the file is broken. `Workflow.summary` falls back to the
                // problem's own sentence then, and the red line below says the same
                // thing better and next to the file it is about — twice is a stutter,
                // and the grey copy is the one carrying less.
                if summary.workflow.problem == nil {
                    Text(summary.workflow.summary)
                        .appText(.supporting)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 4) {
                actions(summary)
                // They write the workflow's file (#125), so say so where they are.
                Text(summary.switchesSentence)
                    .appText(.fine)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 260, alignment: .trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 6)
        }
    }

    /// Run it, and put it away or bring it back — on the title line, where the same
    /// two are on a chat. Words rather than the row's icon: there is one of each here.
    private func actions(_ summary: WorkflowSummary) -> some View {
        HStack(spacing: 8) {
            if summary.isArchived {
                Button("Bring Back") { Task { await model.setWorkflowArchived(summary, false) } }
                    .buttonStyle(.paperProminent)
            } else {
                if summary.isUnapproved {
                    // This page is where the file is read, so this is where approving it
                    // means most. Run now comes back once it is approved. One waiting its
                    // turn behind three others has none yet (#132); the page says why.
                    if summary.canBeApproved {
                        Button("Approve") { Task { await model.approveWorkflow(summary) } }
                            .buttonStyle(.paperProminent)
                            .help("Let this workflow run as its file now reads")
                    }
                    // The third answer (#391): not on this host, with nothing written
                    // into the file, so every other host still sees it waiting.
                    if summary.canBeDenied {
                        Button("Deny on This Host") { Task { await model.denyWorkflow(summary) } }
                            .buttonStyle(.paper)
                            .help("Don't run it on this host. Other hosts still see it waiting; Approve takes this back")
                    }
                } else {
                    // Offered even on a workflow that cannot fire on its own. Being able to
                    // try one is what makes writing one worth doing, and a refusal says why
                    // rather than nothing happening.
                    Button(summary.isRunning ? "Running…" : "Run now") {
                        Task { await model.runWorkflow(summary) }
                    }
                    .buttonStyle(.paperProminent)
                    .disabled(summary.isRunning)
                }
                // Beside Run now, which still works with it off (#100): off stops the
                // triggers, not the person.
                Toggle("Enabled", isOn: Binding(
                    get: { summary.isEnabled },
                    set: { on in Task { await model.setWorkflowEnabled(summary, on) } }))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .appText(.fine)
                    .help(summary.isEnabled
                          ? "Turn this workflow off: its triggers stop, and it stays on the list. Writes enabled: false into its file"
                          : "Turn this workflow back on. Takes enabled: false out of its file")
                    .accessibilityLabel("Enabled")
                // One click, and back to the project: the same thing the archive
                // button on a chat does, so putting a thing away is one gesture
                // wherever it is.
                Button {
                    Task {
                        await model.setWorkflowArchived(summary, true)
                        model.openWorkflow = nil
                    }
                } label: {
                    Label("Archive", systemImage: "archivebox")
                }
                .buttonStyle(.paper)
                .help("Archive this workflow and go back to the project. Writes archived: true into its file")
            }
        }
    }

    /// What the file could not say, and the file itself.
    ///
    /// The raw text is here because the problem alone is not enough to act on: a
    /// person told their metadata block is never closed still has to go and look, and
    /// the thing they need to look at is a dozen lines long and already in hand.
    /// The problem itself is the status card's first line; this is the file under it.
    @ViewBuilder
    private func broken(_ workflow: Workflow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let rawText {
                block(rawText)
            }
        }
        .task(id: workflow) { rawText = await readRaw(workflow) }
    }

    // MARK: Why it is or isn't running (#142)

    /// Everything that decides whether it runs, a line each, most important first:
    /// what stops it, then what it is doing, then when it next runs. The heading keeps
    /// only the summary sentence, so none of this is said twice.
    private func status(_ summary: WorkflowSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Status")
            VStack(alignment: .leading, spacing: 0) {
                let lines = summary.statusLines
                ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                    if index > 0 { Divider().padding(.leading, 42) }
                    statusRow(line)
                }
            }
            .paperRaised(in: RoundedRectangle(cornerRadius: 18))
        }
    }

    private func statusRow(_ line: WorkflowStatusLine) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: line.symbol)
                .appText(.reading)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(line.text)
                    .appText(.reading)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = line.detail {
                    Text(detail)
                        .appText(.fine)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            if let agentID = line.agentID {
                Button {
                    model.openWorkflow = nil
                    model.selection = agentID
                } label: {
                    HStack(spacing: 2) {
                        Text("Open the agent")
                        Image(systemName: "arrow.right")
                    }
                }
                .buttonStyle(.link)
                .appText(.fine)
            }
        }
        .foregroundStyle(line.tint.style(or: .primary))
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    // MARK: What sends it (#98)

    /// What makes it run, a line a trigger, read-only like the rest of the file: what it
    /// waits for, the filters on it, whose agents and events it listens to, when a
    /// schedule is next due, and under them when it last ran and on what.
    ///
    /// Shown for a broken file too, as far as the file could be read: a file with a bad
    /// `options:` still says what would have run it, and that is the half of it the
    /// person is likeliest to remember writing.
    @ViewBuilder
    private func triggers(_ summary: WorkflowSummary) -> some View {
        let triggers = summary.workflow.triggers
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Triggers")
            if triggers.isEmpty {
                note("None could be read from the file.")
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(triggers.enumerated()), id: \.offset) { index, trigger in
                        if index > 0 { Divider().padding(.leading, 42) }
                        triggerRow(trigger, at: index, summary)
                    }
                }
                .paperRaised(in: RoundedRectangle(cornerRadius: 18))
            }
            if let statuses = summary.mcpTriggers, !statuses.isEmpty {
                MCPTriggerLines(statuses: statuses) { status in
                    Task { await model.clearMCPMissed(summary, status) }
                }
            }
            cooldown(summary)
            whenDone(summary)
        }
    }

    /// What a run may do with its session when it is done (#433), with a menu that
    /// writes `when-done:` into the file. Not for a triggering workflow: the agent it
    /// borrows is somebody else's, and stays theirs.
    @ViewBuilder
    private func whenDone(_ summary: WorkflowSummary) -> some View {
        if summary.workflow.mode != .triggering {
            let current = summary.workflow.whenDone ?? .park
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "archivebox")
                    .appText(.fine)
                    .foregroundStyle(.secondary)
                note(current.sentence)
                Spacer(minLength: 12)
                Picker("When done", selection: Binding(
                    get: { current },
                    set: { chosen in
                        guard chosen != current else { return }
                        Task {
                            await model.setWorkflowSettings(summary, summary.workflow.settings,
                                                            whenDone: chosen.rawValue)
                        }
                    })) {
                    ForEach(WorkflowWhenDone.allCases, id: \.self) { choice in
                        Text(choice.words).tag(choice)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .disabled(summary.workflow.settingsLocked)
            }
        }
    }

    /// The lengths the cooldown menu offers. The file can say any other, and the menu
    /// then offers that one too.
    private static let cooldownChoices: [TimeInterval] = [5, 15, 30, 60, 4 * 60, 24 * 60].map { $0 * 60 }

    /// How often it may run (#103): the cooldown, when it ends and whether a trigger is
    /// held for then, with a menu that writes `cooldown:` into the file.
    private func cooldown(_ summary: WorkflowSummary) -> some View {
        let current = summary.workflow.cooldown
        let choices = Self.cooldownChoices + (current.map { Self.cooldownChoices.contains($0) ? [] : [$0] } ?? [])
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "hourglass")
                .appText(.fine)
                .foregroundStyle(.secondary)
            note(summary.cooldownSentence { $0.formatted(date: .omitted, time: .shortened) }
                 ?? "No cooldown: every trigger runs it, one run at a time.")
            Spacer(minLength: 12)
            Picker("Cooldown", selection: Binding(
                get: { current },
                set: { chosen in
                    guard chosen != current else { return }
                    Task {
                        await model.setWorkflowSettings(summary, summary.workflow.settings,
                                                        cooldown: chosen.map(WorkflowCooldown.fileText) ?? "")
                    }
                })) {
                Text("No cooldown").tag(TimeInterval?.none)
                ForEach(choices.sorted(), id: \.self) { length in
                    Text("Cooldown: \(WorkflowCooldown.words(length))").tag(TimeInterval?.some(length))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            .disabled(summary.workflow.settingsLocked)
        }
    }

    private func triggerRow(_ trigger: WorkflowTrigger, at index: Int, _ summary: WorkflowSummary) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol(for: trigger))
                .appText(.reading)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(trigger.summary)
                        .appText(.reading)
                        .fixedSize(horizontal: false, vertical: true)
                    if !trigger.isSupported {
                        Text("Unknown")
                            .appText(.fine).fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .overlay(Capsule().strokeBorder(.secondary.opacity(0.5)))
                            .help("This version does not know this trigger, so it never runs the workflow")
                    }
                }
                if !trigger.filters.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(trigger.filters.sorted { $0.key < $1.key }, id: \.key) { key, value in
                            Text("\(key): \(value.capsule)")
                                .appText(.fine).monospaced()
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                        }
                    }
                }
                if let scope = scopeLine(trigger) {
                    note(scope)
                }
                if summary.workflow.mode == .triggering, trigger.isSupported {
                    note(trigger.resumedAgent)
                }
            }
            Spacer(minLength: 12)
            if trigger.schedule != nil {
                Text(nextLine(at: index, summary))
                    .appText(.fine)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func symbol(for trigger: WorkflowTrigger) -> String {
        switch trigger {
        case .schedule: return "clock"
        case .agentFinished, .agentAskedPermission, .agentAskedForm, .agentStopped: return "person.crop.circle"
        case .workflowCompleted: return "arrow.triangle.2.circlepath"
        case .event(let pattern):
            switch EventSubject(name: pattern.name) {
            case .agent: return "person.crop.circle"
            case .project: return "person.2"
            case .workflow: return "arrow.triangle.2.circlepath"
            case .branch: return "arrow.triangle.branch"
            case .dropbox: return "tray.and.arrow.down"
            case .custom: return "sparkle"
            default: return "desktopcomputer"
            }
        case .serverEvent: return "antenna.radiowaves.left.and.right"
        case .unrecognised: return "questionmark.circle"
        }
    }

    /// Whose agents and events it listens to, by name: this project's, or the host's
    /// as a whole. A schedule says whose clock, since a server's may not be this Mac's.
    private func scopeLine(_ trigger: WorkflowTrigger) -> String? {
        // "this Mac" mid-sentence, as the project page's own line writes it.
        let host = model.isOnThisMac(model.selectedProjectHost)
            ? "this Mac" : model.hosts.label(model.selectedProjectHost)
        let project = model.selectedProject?.lastPathComponent ?? "this project"
        if trigger.schedule != nil { return "By the clock on \(host)" }
        switch trigger.listensIn {
        case .project?: return "In \(project), on \(host)"
        case .mac?: return "Anywhere on \(host), so it runs in every project"
        case .either?: return "In \(project), or anywhere on \(host)"
        case nil: return nil
        }
    }

    /// When a schedule is next due, or why it is not. The time is the daemon's, which
    /// knows the host's clock.
    private func nextLine(at index: Int, _ summary: WorkflowSummary) -> String {
        if summary.isArchived { return "Archived — no next time" }
        if !summary.isEnabled { return "Off — no next time" }
        if summary.workflow.problem != nil { return "Never, until the file is fixed" }
        if summary.isUnapproved { return "No next time until you approve it" }
        if summary.overLimit != nil { return "Over the limit — no next time" }
        // A daemon from before #98 sends only the soonest, which is the one schedule's
        // when there is only one.
        let due = summary.nextFireAtByTrigger.indices.contains(index)
            ? summary.nextFireAtByTrigger[index]
            : (summary.workflow.schedules.count == 1 ? summary.nextFireAt : nil)
        guard let due else { return "No next time" }
        return "Next \(due.formatted(.relative(presentation: .named)))\n"
            + due.formatted(date: .abbreviated, time: .shortened)
    }

    /// When it last started an agent, and what set that off.
    @ViewBuilder
    private func lastRan(_ summary: WorkflowSummary) -> some View {
        if let at = summary.lastFiredAt {
            let when = at.formatted(.relative(presentation: .named))
            note(["Last ran \(when)", summary.lastFiredBy?.phrase].compactMap { $0 }.joined(separator: ", ") + ".")
        } else {
            note("Has not run yet.")
        }
    }

    // MARK: The form, shaped like the prompt bar

    /// The file top left, the runtime top right, the prompt in the middle, and the
    /// settings under it — the prompt bar's own arrangement, because this is a prompt
    /// that sends itself.
    ///
    /// The settings are the ones the file can hold: the mode, the model and the
    /// effort by name, and under them every other option the runtime last advertised
    /// here — fast mode, and whatever a runtime offers next — each written under
    /// `options:` by its own id. Each control has four states,
    /// and the two that are not the ordinary menu carry the explanation: a value the
    /// runtime does not offer is why this workflow is refusing every fire, and this
    /// page is where that gets said, with what it does offer; nothing remembered means
    /// the choices are not known until the runtime has been used in this project, and
    /// the file's value is shown rather than an empty menu or an invented one (FR-024).
    ///
    /// The controls are driven from the file's own values rather than state of their
    /// own: a change goes to the daemon, which writes the file and answers with what it
    /// now says, and a refusal leaves the file alone — so the menu snaps back to the
    /// truth without a second mechanism (FR-025).
    ///
    /// A `triggering` workflow resumes an agent that is already running and never
    /// applies a mode, so its controls are shown and disabled under one line saying so.
    /// Shown rather than hidden, because a person changing `agent:` in the file needs
    /// to find them again — and because a hidden control is not an explanation.
    private func form(_ summary: WorkflowSummary) -> some View {
        let workflow = summary.workflow
        return VStack(alignment: .leading, spacing: 8) {
            sectionTitle("What it does")
            GlassEffectContainer(spacing: 12) {
                VStack(alignment: .leading, spacing: 12) {
                    fileAndRuntime(summary)
                    agentRow(summary)
                    block(workflow.prompt.isEmpty ? "(no prompt)" : workflow.prompt)
                    if workflow.settingsLocked {
                        note(Workflow.settingsLockedNote)
                    }
                    switch workflow.mode {
                    case .triggering:
                        note("This workflow resumes the agent that triggered it, so these do not apply.")
                    case .standing:
                        note("Applied when its standing agent is started, and again if it has to be replaced.")
                    case .new:
                        EmptyView()
                    }
                    // The prompt's two pills: the permission mode on the left, and the
                    // model, its effort and the rest behind one pill on the right.
                    if let runtime = RuntimeCatalog.runtime(id: runtimeID(workflow)) {
                        HStack(alignment: .top, spacing: 10) {
                            settingControl(summary, name: "Permission mode",
                                           setting: WorkflowSettings.Setting.permissionMode,
                                           value: workflow.settings.permissionMode,
                                           option: remembered.flatMap(ModeMemory.modeOption(in:)),
                                           runtime: runtime,
                                           chosen: binding(summary, \.permissionMode) { $0.permissionMode = $1 })
                            Spacer(minLength: 16)
                            modelPill(summary, runtime: runtime)
                        }
                        .disabled(workflow.mode == .triggering || workflow.settingsLocked)
                        refusals(summary, runtime: runtime)
                    }
                    labelsRow(summary)
                        .disabled(workflow.settingsLocked)
                }
            }
        }
        // Asked again when the runtime or the folder changes, and not otherwise: the
        // answer is the daemon's memory, and it starts nothing to give it.
        .task(id: RememberedKey(runtimeID: runtimeID(workflow), folder: workflow.folder)) {
            remembered = nil
            remembered = await model.rememberedOptions(runtimeID: runtimeID(workflow), cwd: workflow.folder)
        }
    }

    /// Who gets the prompt (#142): `agent:` said in words, read-only like the rest of
    /// what the workflow is, and for a standing workflow the agent it keeps.
    private func agentRow(_ summary: WorkflowSummary) -> some View {
        let mode = summary.workflow.mode
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: mode.symbol)
                .appText(.fine)
                .foregroundStyle(.secondary)
            Text(mode.words)
                .appText(.fine)
            Text("agent: \(mode.rawValue)")
                .appText(.fine).monospaced()
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            if mode == .standing {
                standingAgent(summary)
            }
        }
    }

    /// The standing agent by name, a click from its conversation, or that the next run
    /// starts one: the agent the daemon keeps for it (#142), while it is still here.
    @ViewBuilder
    private func standingAgent(_ summary: WorkflowSummary) -> some View {
        if let id = summary.standingAgentID,
           let kept = model.work.agent(id), kept.archivedAt == nil {
            Button {
                model.openWorkflow = nil
                model.selection = kept.id
            } label: {
                HStack(spacing: 2) {
                    Text(kept.title ?? "Untitled")
                    Image(systemName: "arrow.right")
                }
            }
            .buttonStyle(.link)
            .appText(.fine)
            .lineLimit(1)
        } else {
            Text("Started on the next run")
                .appText(.fine)
                .foregroundStyle(.secondary)
        }
    }

    /// The labels each run's new agent gets, in the tag input sessions use (#50): a
    /// comma adds one, Delete takes one away, and each change writes `labels:` in the
    /// file through the daemon, as the other settings do.
    private func labelsRow(_ summary: WorkflowSummary) -> some View {
        let labels = summary.workflow.settings.labels
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "tag")
                    .appText(.fine)
                    .foregroundStyle(.secondary)
                LabelTagField(labels: labels.map { SessionLabel(value: $0, owner: .person) },
                              suggestions: model.labelSuggestions(in: summary.folder, on: model.selectedProjectHost),
                              add: { values in setLabels(summary, labels + values) },
                              remove: { value in
                                  setLabels(summary, labels.filter { SessionLabelPolicy.key($0) != SessionLabelPolicy.key(value) })
                              })
                .task(id: ProjectKey(host: model.selectedProjectHost, folder: summary.folder)) {
                    await model.loadLabelVocabulary(in: summary.folder, on: model.selectedProjectHost)
                }
            }
            note(summary.workflow.labelsNote)
        }
    }

    /// Which computers run it (#317). The names are the ones already on screen.
    private func hostsSection(_ summary: WorkflowSummary) -> some View {
        WorkflowHostsSection(choices: model.workflowHostChoices,
                             hosts: summary.workflow.hosts ?? [],
                             locked: summary.workflow.settingsLocked) { next in
            Task { await model.setWorkflowSettings(summary, summary.workflow.settings, hosts: next) }
        }
    }

    private func setLabels(_ summary: WorkflowSummary, _ labels: [String]) {
        Task { await model.setWorkflowSettings(summary, summary.workflow.settings, labels: labels) }
    }

    // MARK: The rest of the file (#142)

    /// Front-matter keys this version does not know, with what the file says, so the
    /// reader knows the file says more than the page does. Grey: a key from a later
    /// version asks nothing of anyone.
    @ViewBuilder
    private func unknownKeys(_ workflow: Workflow) -> some View {
        if !workflow.unknownFields.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                sectionTitle("From a later version")
                VStack(alignment: .leading, spacing: 6) {
                    note("This version does not understand these lines in the file. They are kept as they are when the page changes it.")
                    ForEach(workflow.unknownLines, id: \.self) { line in
                        Text(line)
                            .appText(.code)
                            .textSelection(.enabled)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .paperRaised(in: RoundedRectangle(cornerRadius: 18))
            }
        }
    }

    /// The file on the left, where the bar has the folder; the runtime on the right,
    /// where the bar has its picker.
    private func fileAndRuntime(_ summary: WorkflowSummary) -> some View {
        let workflow = summary.workflow
        let file = url(workflow)
        let here = model.isOnThisMac(model.selectedProjectHost)
        return HStack(spacing: 12) {
            if here {
                Button {
                    model.reveal(file, on: model.selectedProjectHost)
                } label: {
                    Label(file.lastPathComponent, systemImage: "doc.text")
                        .lineLimit(1)
                }
                .buttonStyle(.paper)
                .appText(.fine)
                .help("\(file.path) — click to show in Finder")
            } else {
                // The file is on the host. Finder here cannot show it (058, FR-019).
                Label(file.lastPathComponent, systemImage: "doc.text")
                    .appText(.fine)
                    .lineLimit(1)
                    .help("On \(model.hosts.label(model.selectedProjectHost)). Open it there.")
            }
            Spacer(minLength: 8)
            runtimeControl(summary)
                .disabled(workflow.mode == .triggering || workflow.settingsLocked)
        }
    }

    private struct RememberedKey: Hashable {
        var runtimeID: String
        var folder: URL
    }

    /// The runtime the file names, or the one a workflow runs on when it names none.
    private func runtimeID(_ workflow: Workflow) -> String {
        workflow.settings.runtimeID ?? RuntimeCatalog.defaultRuntime.id
    }

    /// The runtime, from the catalog rather than from anything remembered: which
    /// runtimes exist is this app's to know. A value the catalog does not hold is shown
    /// and marked, because that workflow is refusing every fire on it (FR-009).
    private func runtimeControl(_ summary: WorkflowSummary) -> some View {
        let named = summary.workflow.settings.runtimeID
        let fallback = RuntimeCatalog.defaultRuntime
        let choices = [ConfigChoice(value: .null, name: "Default (\(fallback.name))")]
            + RuntimeCatalog.builtIn.map { ConfigChoice(value: .string($0.id), name: $0.name) }
        let option = ConfigOption(id: WorkflowSettings.Setting.runtime, name: "Runtime",
                                  kind: .select([ConfigChoiceGroup(name: nil, choices: choices)]),
                                  currentValue: .null)
        return VStack(alignment: .trailing, spacing: 4) {
            OptionMenu(option: option, chosen: binding(summary, \.runtimeID) { $0.runtimeID = $1 })
            if let named, RuntimeCatalog.runtime(id: named) == nil {
                marked("\"\(named)\" is not a runtime this app knows")
            }
        }
    }

    /// One of the settings the runtime itself defines, in the four states the
    /// contract names.
    @ViewBuilder
    private func settingControl(_ summary: WorkflowSummary, name: String, setting: String,
                                value: String?, option: ConfigOption?, runtime: Runtime,
                                chosen: Binding<JSONValue?>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let option {
                OptionMenu(option: withDefault(option, named: name),
                           chosen: chosen)
                if let value, !(option.options ?? []).contains(where: { $0.value.stringValue == value }) {
                    // The same sentence the row carries for the refusal, so the page
                    // and the row cannot describe the one problem two ways.
                    marked(WorkflowSettings.refusalDetail(
                        setting: setting, value: value,
                        offered: (option.options ?? []).map { $0.value.stringValue ?? $0.name },
                        runtime: runtime.name))
                }
            } else {
                Text("\(name): \(value ?? "runtime default")")
                    .appText(.fine)
                    .foregroundStyle(.secondary)
                if remembered != nil {
                    note("The choices are not known until \(runtime.name) has been used in this project.")
                }
            }
        }
    }

    /// The model, the effort and every other option the runtime advertised, behind one
    /// pill, each written where the file keeps it: the model and effort under their own
    /// keys, the rest under `options:` by the option's own id.
    @ViewBuilder
    private func modelPill(_ summary: WorkflowSummary, runtime: Runtime) -> some View {
        let workflow = summary.workflow
        let model = remembered.flatMap(WorkflowSettings.modelOption(in:))
        let effort = remembered.flatMap(WorkflowSettings.effortOption(in:))
        let options = [model.map { withDefault($0, named: "Model") },
                       effort.map { withDefault($0, named: "Effort") }].compactMap { $0 }
            + others.map { withDefault(selectable($0), named: $0.name) }
        if options.isEmpty {
            VStack(alignment: .trailing, spacing: 4) {
                Text("Model: \(workflow.settings.model ?? "runtime default")")
                    .appText(.fine)
                    .foregroundStyle(.secondary)
                if remembered != nil {
                    note("The choices are not known until \(runtime.name) has been used in this project.")
                }
            }
        } else {
            ModelPill(options: options) { option in
                switch option.id {
                case model?.id: return binding(summary, \.model) { $0.model = $1 }
                case effort?.id: return binding(summary, \.effort) { $0.effort = $1 }
                default: return optionBinding(summary, id: option.id)
                }
            }
        }
    }

    /// What the runtime advertised besides the mode, the model and the effort.
    private var others: [ConfigOption] {
        let advertised = remembered ?? []
        return advertised.filter { $0.isRenderable && !WorkflowSettings.isNamedOnItsOwn($0, in: advertised) }
    }

    /// Each value the file names that the runtime does not offer, said under the pills,
    /// because that workflow is refusing every fire on it.
    @ViewBuilder
    private func refusals(_ summary: WorkflowSummary, runtime: Runtime) -> some View {
        let settings = summary.workflow.settings
        let named: [(String, String?, ConfigOption?)] =
            [(WorkflowSettings.Setting.model, settings.model, remembered.flatMap(WorkflowSettings.modelOption(in:))),
             (WorkflowSettings.Setting.effort, settings.effort, remembered.flatMap(WorkflowSettings.effortOption(in:)))]
            + others.map { ($0.id, shown(settings.options[$0.id], for: $0), selectable($0)) }
        let unknown = settings.options.keys.filter { id in !others.contains { $0.id == id } }.sorted()
        ForEach(named.filter { _, value, option in
            guard let value, let option else { return false }
            return !(option.options ?? []).contains { $0.value.stringValue == value }
        }, id: \.0) { setting, value, option in
            marked(WorkflowSettings.refusalDetail(
                setting: setting, value: value ?? "",
                offered: (option?.options ?? []).map { $0.value.stringValue ?? $0.name },
                runtime: runtime.name))
        }
        ForEach(unknown, id: \.self) { id in
            marked("\(id): \(settings.options[id] ?? "") — \(runtime.name) does not offer this option here")
        }
    }

    /// A boolean the file wrote as `yes` or `on` is the menu's `true`, which is how the
    /// start path reads it too — not a value to mark as refused.
    private func shown(_ value: String?, for option: ConfigOption) -> String? {
        guard option.isBoolean, let value, let flag = WorkflowSettings.boolean(value) else { return value }
        return String(flag)
    }

    /// A boolean as a menu, because a toggle cannot say "the runtime's default", and
    /// leaving the key out is a thing a workflow has to be able to say. The values are
    /// the words the file holds.
    private func selectable(_ option: ConfigOption) -> ConfigOption {
        guard option.isBoolean else { return option }
        var copy = option
        copy.kind = .select([ConfigChoiceGroup(name: nil, choices: [
            ConfigChoice(value: .string("true"), name: "\(option.name) on"),
            ConfigChoice(value: .string("false"), name: "\(option.name) off"),
        ])])
        return copy
    }

    /// The runtime's option with a way to say nothing: the first choice leaves the key
    /// out of the file, which is what a workflow that never mentioned it has.
    ///
    /// Every one carries its name in the default, the mode, the model and the effort
    /// too: a chosen value reads for itself — `Plan`, `High` — but `Runtime default`
    /// three times over says nothing about which menu is which.
    private func withDefault(_ option: ConfigOption, named name: String) -> ConfigOption {
        var copy = option
        copy.name = name
        copy.currentValue = .null
        let label = "\(name): runtime default"
        let leading = ConfigChoiceGroup(name: nil, choices: [ConfigChoice(value: .null, name: label)])
        copy.kind = .select([leading] + option.groups)
        return copy
    }

    /// A menu's value, read from the file and written through the daemon. `.null` is
    /// the key left out, which is what the "default" choice means.
    private func binding(_ summary: WorkflowSummary,
                         _ read: KeyPath<WorkflowSettings, String?>,
                         write: @escaping (inout WorkflowSettings, String?) -> Void) -> Binding<JSONValue?> {
        Binding(get: { summary.workflow.settings[keyPath: read].map(JSONValue.string) ?? .null },
                set: { chosen in
                    var settings = summary.workflow.settings
                    write(&settings, chosen?.stringValue)
                    guard settings != summary.workflow.settings else { return }
                    Task { await model.setWorkflowSettings(summary, settings) }
                })
    }

    /// The same, for one key under `options:`.
    private func optionBinding(_ summary: WorkflowSummary, id: String) -> Binding<JSONValue?> {
        Binding(get: { summary.workflow.settings.options[id].map(JSONValue.string) ?? .null },
                set: { chosen in
                    var settings = summary.workflow.settings
                    settings.options[id] = chosen?.stringValue
                    guard settings != summary.workflow.settings else { return }
                    Task { await model.setWorkflowSettings(summary, settings) }
                })
    }

    private func marked(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle")
            .appText(.fine)
            .foregroundStyle(StateTint.attention.style(or: .secondary))
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: What it has run

    /// The agents this workflow started, newest first, each a click from its
    /// conversation. Drawn with the same row the project page uses, so a run reads
    /// here exactly as it reads there — and carries the same marker saying a workflow
    /// started it. Three to begin with: there is no end to a workflow's runs, and the
    /// form above must not be pushed off the page by them.
    private func history(_ summary: WorkflowSummary) -> some View {
        let workflow = summary.workflow
        let folder = Project.standardize(workflow.folder)
        let started = model.work.agents(inFolder: folder)
            .filter { $0.startedByWorkflow == workflow.workflowID }
            .sorted { $0.createdAt > $1.createdAt }
        return VStack(alignment: .leading, spacing: 8) {
            sectionTitle("History")
            lastRan(summary)
            ForEach(started.prefix(shownRuns)) { agent in
                Button {
                    model.openWorkflow = nil
                    model.selection = agent.id
                } label: {
                    AgentRow(agent: agent)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 13)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(RoundedRectangle(cornerRadius: 14))
                        .paperRow()
                }
                .buttonStyle(.plain)
            }
            if started.count > shownRuns {
                Button("Show more (\(started.count - shownRuns) more)") {
                    shownRuns += Self.runsPerMore
                }
                .buttonStyle(.paper)
                .appText(.reading)
            }
        }
    }

    // MARK: Pieces

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .appText(.fine).fontWeight(.semibold)
            .foregroundStyle(.secondary)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .appText(.fine)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// The prompt, whole, exactly as it will be sent, in the bar's own glass.
    ///
    /// Selectable and not editable. Monospaced because it is a thing that will be sent
    /// verbatim, and because the difference between two spaces and one can matter to
    /// what an agent does with it.
    private func block(_ text: String) -> some View {
        Text(text)
            .appText(.code)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(14)
            .paperRaised(in: RoundedRectangle(cornerRadius: 18))
    }

    private func url(_ workflow: Workflow) -> URL {
        WorkflowPaths.url(for: workflow.workflowID, in: workflow.folder)
    }

    /// The file as its host reads it (058, R11), this Mac's included.
    private func readRaw(_ workflow: Workflow) async -> String? {
        await model.readText(url(workflow), on: model.selectedProjectHost)
    }
}
