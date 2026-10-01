import AgentsKitCore
#if !AGENTS_STORE
import AgentsKit
#endif
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
/// be changed from here is how much the workflow is allowed to do.
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
    }

    @ViewBuilder
    private func content(_ summary: WorkflowSummary) -> some View {
        let workflow = summary.workflow
        VStack(alignment: .leading, spacing: 22) {
            heading(summary)
            if let problem = workflow.problem {
                broken(problem, workflow: workflow)
            }
            form(summary)
            runs(workflow)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // The column the transcript, the prompt bar and the project page all use, so
        // this reads as another page of the same document rather than a panel.
        .chatColumn()
        .padding(.top, 28)
        .padding(.bottom, 40)
    }

    // MARK: The title line

    /// The name, what it is, and what is happening to it — the row's three lines, in
    /// the row's words — and on the right, the two things you do to a workflow.
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
                if let happening = happening(summary) {
                    HStack(spacing: 4) {
                        Text(happening)
                        if let agentID = ranAgentID(summary) {
                            Text("·")
                            Button {
                                model.openWorkflow = nil
                                model.selection = agentID
                            } label: {
                                HStack(spacing: 2) {
                                    Text("Open the agent it started")
                                    Image(systemName: "arrow.right")
                                }
                            }
                            .buttonStyle(.link)
                        }
                    }
                    .appText(.supporting)
                    .foregroundStyle((summary.needsAPerson ? StateTint.attention : .none).style(or: .secondary))
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            actions(summary)
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
                if summary.awaitingApproval != nil {
                    // This page is where the file is read, so this is where approving it
                    // means most. Run now comes back once it is approved.
                    Button("Approve") { Task { await model.approveWorkflow(summary) } }
                        .buttonStyle(.paperProminent)
                        .help("Let this workflow run as its file now reads")
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
                .help("Archive this workflow and go back to the project")
            }
        }
    }

    /// What the file could not say, and the file itself.
    ///
    /// The raw text is here because the problem alone is not enough to act on: a
    /// person told their metadata block is never closed still has to go and look, and
    /// the thing they need to look at is a dozen lines long and already in hand.
    @ViewBuilder
    private func broken(_ problem: WorkflowProblem, workflow: Workflow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(problem.message, systemImage: "exclamationmark.triangle")
                .appText(.reading)
                .tinted(problem.needsAPerson ? .failure : .none)
                .fixedSize(horizontal: false, vertical: true)
            if let rawText {
                block(rawText)
            }
        }
        .task(id: workflow) { rawText = await readRaw(workflow) }
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
        return GlassEffectContainer(spacing: 12) {
            VStack(alignment: .leading, spacing: 12) {
                fileAndRuntime(summary)
                block(workflow.prompt.isEmpty ? "(no prompt)" : workflow.prompt)
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
                    .disabled(workflow.mode == .triggering)
                    refusals(summary, runtime: runtime)
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
                .disabled(workflow.mode == .triggering)
        }
    }

    private struct RememberedKey: Hashable {
        var runtimeID: String
        var folder: URL
    }

    /// The runtime the file names, or the one a workflow runs on when it names none.
    private func runtimeID(_ workflow: Workflow) -> String {
        workflow.settings.runtimeID ?? RuntimeCatalog.builtIn[0].id
    }

    /// The runtime, from the catalog rather than from anything remembered: which
    /// runtimes exist is this app's to know. A value the catalog does not hold is shown
    /// and marked, because that workflow is refusing every fire on it (FR-009).
    private func runtimeControl(_ summary: WorkflowSummary) -> some View {
        let named = summary.workflow.settings.runtimeID
        let fallback = RuntimeCatalog.builtIn[0]
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
    private func runs(_ workflow: Workflow) -> some View {
        let folder = Project.standardize(workflow.folder)
        let started = model.agents
            .filter { $0.projectFolder == folder && $0.startedByWorkflow == workflow.workflowID }
            .sorted { $0.createdAt > $1.createdAt }
        return VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Recent runs")
            if started.isEmpty {
                note("Nothing has run yet.")
            }
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

    /// This Mac's file is read here. Another host's is `files/read`, scoped to an agent
    /// in that project (058, R11). With no such agent there is nothing to scope it to.
    private func readRaw(_ workflow: Workflow) async -> String? {
        let file = url(workflow)
        let host = model.selectedProjectHost
        if model.readsDisk(of: host) { return try? String(contentsOf: file, encoding: .utf8) }  // store-ok: readsDisk(of:) is false in the store window
        #if AGENTS_STORE
        return await model.readText(file, on: host)
        #else
        return await model.textFile(at: file, on: host, agentID: model.anAgent(in: workflow.folder, on: host))
        #endif
    }

    /// When it next runs and what happened last, as one sentence. The row's third line,
    /// which is where a refusal becomes visible at all.
    private func happening(_ summary: WorkflowSummary) -> String? {
        var parts: [String] = []
        if summary.isArchived {
            parts.append("Archived — it will not run until it is restored")
        } else if let waiting = summary.awaitingApproval {
            // What waits on the person is the file, and it is on this page to be read.
            parts.append((waiting.isNew ? "New" : "Changed since you approved it")
                         + " — read it below, then Approve to let it run")
            return parts.joined()
        } else if let limit = summary.overLimit {
            parts.append("\(limit.sentence). \(limit.remedy)")
        } else if let next = summary.nextFireAt {
            parts.append("Next \(next.formatted(.relative(presentation: .named)))")
        }
        if let outcome = summary.lastOutcome {
            let when = outcome.at.formatted(.relative(presentation: .named))
            switch outcome {
            case .ran: parts.append("Ran \(when)")
            case .refused: parts.append(outcome.summary)
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func ranAgentID(_ summary: WorkflowSummary) -> UUID? {
        if case .ran(let agentID, _) = summary.lastOutcome { return agentID }
        return nil
    }
}
