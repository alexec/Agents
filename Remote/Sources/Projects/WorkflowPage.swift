import AgentsKitCore
import SwiftUI

/// One workflow, opened up — the Mac's `WorkflowPage`, on a phone.
///
/// The same reading and the same reach: the prompt as it will be sent, what is
/// happening to it, what it may do, and the agents it has run. The same things change
/// here as change there — the runtime, the permission mode, the model, the effort and
/// the runtime's other options, Run now, and Archive or Restore — and the same things
/// do not. The prompt and the triggers are the author's, and are shown, not edited.
///
/// Laid out as a column rather than the Mac's prompt-bar shape: three menus side by
/// side do not fit a phone, and a row per setting with its name on the left reads
/// the way the phone's own Settings do.
///
/// Every change goes to the Mac, which writes the file and answers with what it now
/// says. The menus are drawn from that answer rather than state of their own, so a
/// refusal puts them back to the truth without a second mechanism (FR-025).
struct WorkflowPage: View {
    @Environment(RemoteModel.self) private var model
    let workflowID: Workflow.ID

    /// What the workflow's runtime last advertised for this project, out of the
    /// daemon's memory. Nil until asked; empty when it has nothing.
    @State private var remembered: [ConfigOption]?
    @State private var shownRuns = Self.runsAtFirst
    /// Whether the Mac has runs past the ones shown. Archived runs are not in the
    /// phone's list until this page asks for them, so it cannot count them itself.
    @State private var moreRuns = false

    private static let runsAtFirst = 3
    private static let runsPerMore = 6

    private var summary: WorkflowSummary? {
        model.workflows.first { $0.id == workflowID }
    }

    var body: some View {
        ScrollView {
            if let summary {
                content(summary)
            } else {
                ContentUnavailableView("This workflow is no longer there",
                                       systemImage: "clock.badge.questionmark",
                                       description: Text("Its file has been removed or renamed."))
                    .padding(.top, 60)
            }
        }
        .navigationTitle(summary?.workflow.name ?? "Workflow")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .top, spacing: 0) { StaleBanner() }
        .markedStale(model.isStale)
        .refreshable { await model.refreshEverything() }
        .toolbar {
            if let summary {
                ToolbarItem(placement: .topBarTrailing) { archiveButton(summary) }
            }
        }
        .onChange(of: workflowID) { shownRuns = Self.runsAtFirst }
        // Its runs, archived ones too, a page at a time; again when one starts.
        .task(id: RunsAsk(workflowID: workflowID, shown: shownRuns, held: summary.map(started)?.count ?? 0)) {
            guard let summary else { return }
            moreRuns = await model.loadRuns(of: summary.workflowID, in: summary.workflow.folder,
                                            limit: shownRuns)
        }
    }

    /// The agents it started that the phone holds, newest first.
    private func started(_ summary: WorkflowSummary) -> [Agent] {
        let folder = Project.standardize(summary.workflow.folder)
        return model.work.agents
            .filter { $0.projectFolder == folder && $0.startedByWorkflow == summary.workflowID }
            .sorted { $0.createdAt > $1.createdAt }
    }

    private func content(_ summary: WorkflowSummary) -> some View {
        let workflow = summary.workflow
        return VStack(alignment: .leading, spacing: 22) {
            heading(summary)
            if let problem = workflow.problem {
                Label(problem.message, systemImage: "exclamationmark.triangle")
                    .appText(.reading)
                    .tinted(problem.needsAPerson ? .failure : .none)
                    .fixedSize(horizontal: false, vertical: true)
            }
            runButton(summary)
            prompt(workflow)
            settings(summary)
            runs(workflow)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 32)
        .frame(maxWidth: .infinity, alignment: .leading)
        .readableWidth()
    }

    // MARK: The title

    /// The name, what it is, and what is happening to it — the row's three lines.
    private func heading(_ summary: WorkflowSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(summary.workflow.name)
                .appText(.title).fontWeight(.semibold)
                .fixedSize(horizontal: false, vertical: true)
            if summary.workflow.problem == nil {
                Text(summary.workflow.summary)
                    .appText(.supporting)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let happening = happening(summary) {
                Text(happening)
                    .appText(.supporting)
                    .foregroundStyle((summary.needsAPerson ? StateTint.attention : .none).style(or: .secondary))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Run now, full width under the title where a thumb finds it, or Restore when it
    /// is put away. Offered even on a workflow that cannot fire on its own: a refusal
    /// says why, which is better than nothing happening.
    @ViewBuilder
    private func runButton(_ summary: WorkflowSummary) -> some View {
        Group {
            if summary.isArchived {
                Button { Task { await model.setWorkflowArchived(summary, false) } } label: {
                    Text("Restore").frame(maxWidth: .infinity)
                }
            } else {
                Button { Task { await model.runWorkflow(summary) } } label: {
                    Text(summary.isRunning ? "Running…" : "Run now").frame(maxWidth: .infinity)
                }
                .disabled(summary.isRunning)
            }
        }
        .buttonStyle(.paperProminent)
        .disabled(model.isStale)
    }

    /// Archive, in the bar, where a chat keeps its own. It goes back to the project, as
    /// the Mac's does: putting a thing away is one gesture wherever it is.
    @ViewBuilder
    private func archiveButton(_ summary: WorkflowSummary) -> some View {
        if !summary.isArchived {
            Button {
                Task {
                    await model.setWorkflowArchived(summary, true)
                    model.openWorkflow = nil
                }
            } label: {
                Label("Archive", systemImage: "archivebox")
            }
            .disabled(model.isStale)
        }
    }

    // MARK: The prompt

    /// The file's name, and the prompt whole, exactly as it will be sent. Selectable,
    /// not editable: it is the author's.
    private func prompt(_ workflow: Workflow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Prompt")
            Label(".agents/workflows/\(workflow.workflowID).md", systemImage: "doc.text")
                .appText(.fine)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(workflow.prompt.isEmpty ? "(no prompt)" : workflow.prompt)
                .appText(.code)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(14)
                .paperRaised(in: RoundedRectangle(cornerRadius: 18))
        }
    }

    // MARK: What it may do

    /// The runtime, then the mode, the model and the effort, then every other option
    /// the runtime last advertised here — one row each. A `triggering` workflow resumes
    /// an agent already running and applies none of them, so they are shown disabled
    /// under a line saying so rather than hidden.
    private func settings(_ summary: WorkflowSummary) -> some View {
        let workflow = summary.workflow
        let runtime = RuntimeCatalog.runtime(id: runtimeID(workflow))
        return VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Settings")
            switch workflow.mode {
            case .triggering:
                note("This workflow resumes the agent that triggered it, so these do not apply.")
            case .standing:
                note("Applied when its standing agent is started, and again if it has to be replaced.")
            case .new:
                EmptyView()
            }
            VStack(alignment: .leading, spacing: 14) {
                runtimeRow(summary)
                if let runtime {
                    settingRow(summary, name: "Permission mode",
                               setting: WorkflowSettings.Setting.permissionMode,
                               value: workflow.settings.permissionMode,
                               option: remembered.flatMap(ModeMemory.modeOption(in:)),
                               runtime: runtime,
                               chosen: binding(summary, \.permissionMode) { $0.permissionMode = $1 })
                    settingRow(summary, name: "Model",
                               setting: WorkflowSettings.Setting.model,
                               value: workflow.settings.model,
                               option: remembered.flatMap(WorkflowSettings.modelOption(in:)),
                               runtime: runtime,
                               chosen: binding(summary, \.model) { $0.model = $1 })
                    settingRow(summary, name: "Effort",
                               setting: WorkflowSettings.Setting.effort,
                               value: workflow.settings.effort,
                               option: remembered.flatMap(WorkflowSettings.effortOption(in:)),
                               runtime: runtime,
                               chosen: binding(summary, \.effort) { $0.effort = $1 })
                    otherOptions(summary, runtime: runtime)
                }
            }
            .padding(14)
            .paperRaised(in: RoundedRectangle(cornerRadius: 18))
            .disabled(workflow.mode == .triggering || model.isStale)
        }
        // Asked again when the runtime or the folder changes, and not otherwise: the
        // answer is the daemon's memory, and it starts nothing to give it.
        .task(id: RememberedKey(runtimeID: runtimeID(workflow), folder: workflow.folder)) {
            remembered = nil
            remembered = await model.rememberedOptions(runtimeID: runtimeID(workflow), cwd: workflow.folder)
        }
    }

    private struct RememberedKey: Hashable {
        var runtimeID: String
        var folder: URL
    }

    private func runtimeID(_ workflow: Workflow) -> String {
        workflow.settings.runtimeID ?? RuntimeCatalog.builtIn[0].id
    }

    /// The runtime, from the catalog: which runtimes exist is the app's to know. A
    /// value the catalog does not hold is shown and marked, because that workflow is
    /// refusing every fire on it (FR-009).
    private func runtimeRow(_ summary: WorkflowSummary) -> some View {
        let named = summary.workflow.settings.runtimeID
        let fallback = RuntimeCatalog.builtIn[0]
        let choices = [ConfigChoice(value: .null, name: "Default (\(fallback.name))")]
            + RuntimeCatalog.builtIn.map { ConfigChoice(value: .string($0.id), name: $0.name) }
        let option = ConfigOption(id: WorkflowSettings.Setting.runtime, name: "Runtime",
                                  kind: .select([ConfigChoiceGroup(name: nil, choices: choices)]),
                                  currentValue: .null)
        return row("Runtime") {
            OptionMenu(option: option, chosen: binding(summary, \.runtimeID) { $0.runtimeID = $1 })
        } below: {
            if let named, RuntimeCatalog.runtime(id: named) == nil {
                marked("\"\(named)\" is not a runtime this app knows")
            }
        }
    }

    /// One setting the runtime defines: its menu when the choices are known, the file's
    /// value and why there is no menu when they are not, and a mark under a value the
    /// runtime does not offer — the reason that workflow is refused.
    private func settingRow(_ summary: WorkflowSummary, name: String, setting: String,
                            value: String?, option: ConfigOption?, runtime: Runtime,
                            chosen: Binding<JSONValue?>) -> some View {
        row(name) {
            if let option {
                OptionMenu(option: withDefault(option, named: name), chosen: chosen)
            } else {
                Text(value ?? "Runtime default")
                    .appText(.reading)
                    .foregroundStyle(.secondary)
            }
        } below: {
            if let option {
                if let value, !(option.options ?? []).contains(where: { $0.value.stringValue == value }) {
                    marked(WorkflowSettings.refusalDetail(
                        setting: setting, value: value,
                        offered: (option.options ?? []).map { $0.value.stringValue ?? $0.name },
                        runtime: runtime.name))
                }
            } else if remembered != nil {
                note("The choices are not known until \(runtime.name) has been used in this project.")
            }
        }
    }

    /// Every other option the runtime advertised, written under `options:` by its own
    /// id, and any the file names that the runtime did not advertise, marked.
    @ViewBuilder
    private func otherOptions(_ summary: WorkflowSummary, runtime: Runtime) -> some View {
        let advertised = remembered ?? []
        let others = advertised.filter {
            $0.isRenderable && !WorkflowSettings.isNamedOnItsOwn($0, in: advertised)
        }
        let unknown = summary.workflow.settings.options.keys
            .filter { id in !others.contains { $0.id == id } }.sorted()
        ForEach(others) { option in
            settingRow(summary, name: option.name, setting: option.id,
                       value: shown(summary.workflow.settings.options[option.id], for: option),
                       option: selectable(option), runtime: runtime,
                       chosen: optionBinding(summary, id: option.id))
        }
        ForEach(unknown, id: \.self) { id in
            settingRow(summary, name: id, setting: id,
                       value: summary.workflow.settings.options[id],
                       option: nil, runtime: runtime,
                       chosen: optionBinding(summary, id: id))
        }
    }

    /// A name on the left, its control on the right, and anything to say about it under
    /// both.
    private func row(_ name: String, @ViewBuilder control: () -> some View,
                     @ViewBuilder below: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(name)
                    .appText(.reading)
                Spacer(minLength: 8)
                control()
            }
            below()
        }
    }

    /// A boolean the file wrote as `yes` or `on` is the menu's `true`.
    private func shown(_ value: String?, for option: ConfigOption) -> String? {
        guard option.isBoolean, let value, let flag = WorkflowSettings.boolean(value) else { return value }
        return String(flag)
    }

    /// A boolean as a menu, because a toggle cannot say "the runtime's default".
    private func selectable(_ option: ConfigOption) -> ConfigOption {
        guard option.isBoolean else { return option }
        var copy = option
        copy.kind = .select([ConfigChoiceGroup(name: nil, choices: [
            ConfigChoice(value: .string("true"), name: "On"),
            ConfigChoice(value: .string("false"), name: "Off"),
        ])])
        return copy
    }

    /// The runtime's option with a way to say nothing: the first choice leaves the key
    /// out of the file. The row already carries the name, so the default does not.
    private func withDefault(_ option: ConfigOption, named name: String) -> ConfigOption {
        var copy = option
        copy.name = name
        copy.currentValue = .null
        let leading = ConfigChoiceGroup(name: nil, choices: [ConfigChoice(value: .null, name: "Runtime default")])
        copy.kind = .select([leading] + option.groups)
        return copy
    }

    /// A menu's value, read from the file and written through the Mac. `.null` is the
    /// key left out.
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

    private func optionBinding(_ summary: WorkflowSummary, id: String) -> Binding<JSONValue?> {
        Binding(get: { summary.workflow.settings.options[id].map(JSONValue.string) ?? .null },
                set: { chosen in
                    var settings = summary.workflow.settings
                    settings.options[id] = chosen?.stringValue
                    guard settings != summary.workflow.settings else { return }
                    Task { await model.setWorkflowSettings(summary, settings) }
                })
    }

    // MARK: What it has run

    /// The agents it started, newest first, as the project page draws them — each a
    /// tap from its conversation, and back comes here. Three to begin with.
    private func runs(_ workflow: Workflow) -> some View {
        let folder = Project.standardize(workflow.folder)
        let started = model.work.agents
            .filter { $0.projectFolder == folder && $0.startedByWorkflow == workflow.workflowID }
            .sorted { $0.createdAt > $1.createdAt }
        return VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Recent runs")
            if started.isEmpty {
                note("Nothing has run yet.")
            }
            ForEach(started.prefix(shownRuns)) { agent in
                AgentCard(agent: agent)
            }
            if started.count > shownRuns || moreRuns {
                Button("Show more") {
                    shownRuns += Self.runsPerMore
                }
                .appText(.reading)
            }
        }
    }

    // MARK: Pieces

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .appText(.reading).fontWeight(.semibold)
            .accessibilityAddTraits(.isHeader)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .appText(.fine)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func marked(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle")
            .appText(.fine)
            .foregroundStyle(StateTint.attention.style(or: .secondary))
            .fixedSize(horizontal: false, vertical: true)
    }

    /// When it next runs and what happened last, as one sentence — the Mac page's.
    private func happening(_ summary: WorkflowSummary) -> String? {
        var parts: [String] = []
        if summary.isArchived {
            parts.append("Archived — it will not run until it is restored")
        } else if summary.isRunning {
            parts.append("Running now")
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
}

/// When a workflow page fetches its runs: opened, paged, or a run arrived.
private struct RunsAsk: Equatable {
    var workflowID: Workflow.ID
    var shown: Int
    var held: Int
}
