import AgentsKitCore
import SwiftUI

/// One workflow, opened up — the Mac's `WorkflowPage`, on a phone.
///
/// The same reading and the same reach, in the same order (#142): why it is or isn't
/// running, what it does (who gets the prompt, the prompt, what it may do, its labels),
/// what the file says that this version does not understand, and the agents it has run.
/// The same things change here as change there — the runtime, the permission mode, the
/// model, the effort and the runtime's other options, the labels, which computers run
/// it, Run now or Approve, and Archive or Bring Back — and the same things do not. The prompt, the triggers
/// and the agent mode are the author's, and are shown, not edited.
///
/// Laid out as a column rather than the Mac's prompt-bar shape: three menus side by
/// side do not fit a phone, and a row per setting with its name on the left reads
/// the way the phone's own Settings do.
///
/// Every change goes to the host being looked at, which writes the file and answers
/// with what it now says. The menus are drawn from that answer rather than state of their own, so a
/// refusal puts them back to the truth without a second mechanism (FR-025).
struct WorkflowPage: View {
    @Environment(RemoteModel.self) private var model
    let workflowID: Workflow.ID

    /// What the workflow's runtime last advertised for this project, out of the
    /// daemon's memory. Nil until asked; empty when it has nothing.
    @State private var remembered: [ConfigOption]?
    @State private var rawWorkflowText: String?
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
        .shows([.workflows])
        .refreshable { await model.catchUp() }
        .toolbar {
            if let summary {
                ToolbarItem(placement: .topBarTrailing) { archiveButton(summary) }
            }
        }
        .onChange(of: workflowID) { shownRuns = Self.runsAtFirst }
        // Its runs, archived ones too, a page at a time; again when one starts.
        .task(id: RunsAsk(workflowID: workflowID, shown: shownRuns)) {
            guard let summary else { return }
            moreRuns = await model.loadRuns(of: summary.workflowID, in: summary.workflow.folder,
                                            limit: shownRuns)
        }
        .task(id: summary?.workflow) {
            guard let workflow = summary?.workflow, workflow.problem?.needsAPerson == true else {
                rawWorkflowText = nil
                return
            }
            guard case .text(let text, let isTruncated, let size, _)? = try? await model.readPage(
                ".agents/workflows/\(workflow.workflowID).md", in: workflow.folder) else { return }
            rawWorkflowText = isTruncated
                ? text + "\n\n" + FileReading.truncationNote(shown: text.utf8.count, of: size)
                : text
        }
    }

    /// The agents it started that the phone holds, newest first.
    private func content(_ summary: WorkflowSummary) -> some View {
        let workflow = summary.workflow
        return VStack(alignment: .leading, spacing: 22) {
            heading(summary)
            runButton(summary)
            status(summary)
            if workflow.problem?.needsAPerson == true { unreadableFile() }
            prompt(summary)
            triggers(summary)
            settings(summary)
            labels(summary)
            hostsSection(summary)
            unknownKeys(workflow)
            runs(workflow)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 32)
        .frame(maxWidth: .infinity, alignment: .leading)
        .readableWidth()
    }

    // MARK: The title

    /// The name and what it is, in the row's words. What is happening to it is the
    /// status card's (#142).
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
        }
    }

    // MARK: Why it is or isn't running (#142)

    /// The Mac page's status card, line for line: what stops it, what it is doing, and
    /// when it next runs.
    private func status(_ summary: WorkflowSummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Status")
            VStack(alignment: .leading, spacing: 0) {
                let lines = summary.statusLines
                ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                    if index > 0 { Divider().padding(.leading, 42) }
                    statusRow(line)
                }
            }
            .paperRaised(in: RoundedRectangle(cornerRadius: 18))
            // How often it may run, the Mac page's sentence under its triggers (#103).
            if let cooldown = summary.cooldownSentence(formatting: { $0.formatted(date: .omitted, time: .shortened) }) {
                note(cooldown)
            }
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
                if let agentID = line.agentID {
                    NavigationLink(value: RemoteRoute.agent(agentID)) {
                        Text("Open the agent")
                    }
                    .appText(.fine)
                }
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(line.tint.style(or: .primary))
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    /// Run now, full width under the title where a thumb finds it, or Bring Back when
    /// it is put away. Offered even on a workflow that cannot fire on its own: a refusal
    /// says why, which is better than nothing happening.
    @ViewBuilder
    private func runButton(_ summary: WorkflowSummary) -> some View {
        Group {
            if summary.isArchived {
                Button { Task { await model.setWorkflowArchived(summary, false) } } label: {
                    Text("Bring Back").frame(maxWidth: .infinity)
                }
            } else {
                VStack(spacing: 12) {
                    if summary.isUnapproved {
                        // As on the Mac: Run now comes back once it is approved, and one
                        // waiting its turn has neither; the status card says why (#132).
                        if summary.canBeApproved {
                            Button { Task { await model.approveWorkflow(summary) } } label: {
                                Text("Approve").frame(maxWidth: .infinity)
                            }
                        }
                        // Not on this host, without archiving it everywhere (#391).
                        if summary.canBeDenied {
                            Button { Task { await model.denyWorkflow(summary) } } label: {
                                Text("Deny on This Host").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.paper)
                        }
                    } else {
                        Button { Task { await model.runWorkflow(summary) } } label: {
                            Text(summary.isRunning ? "Running…" : "Run now").frame(maxWidth: .infinity)
                        }
                        .disabled(summary.isRunning)
                    }
                    // Under Run now, which still works with it off (#100).
                    Toggle("Enabled", isOn: Binding(
                        get: { summary.isEnabled },
                        set: { on in Task { await model.setWorkflowEnabled(summary, on) } }))
                        .appText(.reading)
                    // They write the workflow's file (#125), the Mac page's words.
                    Text(summary.switchesSentence)
                        .appText(.fine)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
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

    /// The file's name, who gets the prompt, and the prompt whole, exactly as it will
    /// be sent. Selectable, not editable: it is the author's.
    private func prompt(_ summary: WorkflowSummary) -> some View {
        let workflow = summary.workflow
        return VStack(alignment: .leading, spacing: 8) {
            sectionTitle("What it does")
            Label(".agents/workflows/\(workflow.workflowID).md", systemImage: "doc.text")
                .appText(.fine)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            agentRow(summary)
            Text(workflow.prompt.isEmpty ? "(no prompt)" : workflow.prompt)
                .appText(.code)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(14)
                .paperRaised(in: RoundedRectangle(cornerRadius: 18))
        }
    }

    /// Who gets the prompt (#142): `agent:` said in words, read-only, and for a
    /// standing workflow the agent it keeps.
    private func agentRow(_ summary: WorkflowSummary) -> some View {
        let mode = summary.workflow.mode
        return VStack(alignment: .leading, spacing: 4) {
            Label(mode.words, systemImage: mode.symbol)
                .appText(.reading)
            Text("agent: \(mode.rawValue)")
                .appText(.fine).monospaced()
                .foregroundStyle(.secondary)
            if mode == .standing {
                standingAgent(summary)
            }
        }
    }

    /// The agent the Mac keeps for it, a tap from its conversation, or that the next
    /// run starts one.
    @ViewBuilder
    private func standingAgent(_ summary: WorkflowSummary) -> some View {
        if let id = summary.standingAgentID, let kept = model.work.agent(id), kept.archivedAt == nil {
            NavigationLink(value: RemoteRoute.agent(kept.id)) {
                Label(kept.title ?? "Untitled", systemImage: "arrow.right")
                    .lineLimit(1)
            }
            .appText(.fine)
        } else {
            Text("Started on the next run")
                .appText(.fine)
                .foregroundStyle(.secondary)
        }
    }

    /// The workflow source is useful when its front matter cannot be parsed.
    private func unreadableFile() -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("The file is below")
            if let rawWorkflowText {
                Text(rawWorkflowText)
                    .appText(.code)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(14)
                    .paperRaised(in: RoundedRectangle(cornerRadius: 18))
            } else {
                note("The workflow file could not be read from the host.")
            }
        }
    }

    // MARK: Triggers and cooldown

    private func triggers(_ summary: WorkflowSummary) -> some View {
        let triggers = summary.workflow.triggers
        return VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Triggers")
            if triggers.isEmpty {
                note("None could be read from the file.")
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(triggers.enumerated()), id: \.offset) { index, trigger in
                        if index > 0 { Divider() }
                        triggerRow(trigger, at: index, summary)
                    }
                }
                .paperRaised(in: RoundedRectangle(cornerRadius: 18))
            }
            if let statuses = summary.mcpTriggers, !statuses.isEmpty {
                MCPTriggerLines(statuses: statuses, clear: { status in
                    Task { await model.clearMCPMissed(summary, status) }
                }, disabled: model.isStale)
            }
            cooldown(summary)
            whenDone(summary)
            if let at = summary.lastFiredAt {
                note(["Last ran \(at.formatted(.relative(presentation: .named)))", summary.lastFiredBy?.phrase]
                    .compactMap { $0 }.joined(separator: ", ") + ".")
            } else {
                note("Has not run yet.")
            }
        }
    }

    private static let cooldownChoices: [TimeInterval] = [5, 15, 30, 60, 240, 1440].map { $0 * 60 }

    private func cooldown(_ summary: WorkflowSummary) -> some View {
        let current = summary.workflow.cooldown
        let choices = Self.cooldownChoices + (current.map { Self.cooldownChoices.contains($0) ? [] : [$0] } ?? [])
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            note(summary.cooldownSentence { $0.formatted(date: .omitted, time: .shortened) }
                 ?? "No cooldown: every trigger runs it, one run at a time.")
            Spacer(minLength: 8)
            Picker("Cooldown", selection: Binding<TimeInterval?>(
                get: { current },
                set: { chosen in
                    guard chosen != current else { return }
                    Task { await model.setWorkflowSettings(summary, summary.workflow.settings,
                                                           cooldown: chosen.map(WorkflowCooldown.fileText) ?? "") }
                })) {
                Text("No cooldown").tag(TimeInterval?.none)
                ForEach(choices.sorted(), id: \.self) { length in
                    Text("Cooldown: \(WorkflowCooldown.words(length))").tag(TimeInterval?.some(length))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            .disabled(summary.workflow.settingsLocked || model.isStale)
        }
    }

    /// What a run may do with its session when it is done (#433), as the window's page
    /// has it. Not for a triggering workflow, whose agent is somebody else's.
    @ViewBuilder
    private func whenDone(_ summary: WorkflowSummary) -> some View {
        if summary.workflow.mode != .triggering {
            let current = summary.workflow.whenDone ?? .park
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                note(current.sentence)
                Spacer(minLength: 8)
                Picker("When done", selection: Binding<WorkflowWhenDone>(
                    get: { current },
                    set: { chosen in
                        guard chosen != current else { return }
                        Task { await model.setWorkflowSettings(summary, summary.workflow.settings,
                                                               whenDone: chosen.rawValue) }
                    })) {
                    ForEach(WorkflowWhenDone.allCases, id: \.self) { choice in
                        Text(choice.words).tag(choice)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .disabled(summary.workflow.settingsLocked || model.isStale)
            }
        }
    }

    private func triggerRow(_ trigger: WorkflowTrigger, at index: Int, _ summary: WorkflowSummary) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: trigger.schedule != nil ? "clock" : "bolt")
                .appText(.reading).foregroundStyle(.secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 4) {
                Text(trigger.summary).appText(.reading).fixedSize(horizontal: false, vertical: true)
                if !trigger.isSupported {
                    Text("Unknown")
                        .appText(.fine).fontWeight(.semibold).foregroundStyle(.secondary)
                        .padding(.horizontal, 6).overlay(Capsule().strokeBorder(.secondary.opacity(0.5)))
                }
                ForEach(trigger.filters.sorted { $0.key < $1.key }, id: \.key) { key, value in
                    Text("\(key): \(value.capsule)").appText(.fine).monospaced()
                }
                if let scope = scopeLine(trigger) { note(scope) }
                if trigger.schedule != nil {
                    note(nextLine(at: index, summary))
                }
                if summary.workflow.mode == .triggering && trigger.isSupported { note(trigger.resumedAgent) }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func scopeLine(_ trigger: WorkflowTrigger) -> String? {
        let project = summaryProjectName
        if trigger.schedule != nil { return "By the host's clock" }
        switch trigger.listensIn {
        case .project?: return "In \(project)"
        case .mac?: return "Anywhere on this host, so it runs in every project"
        case .either?: return "In \(project), or anywhere on this host"
        case nil: return nil
        }
    }

    private var summaryProjectName: String {
        model.selectedProject?.lastPathComponent ?? "this project"
    }

    private func nextLine(at index: Int, _ summary: WorkflowSummary) -> String {
        if summary.isArchived { return "Archived — no next time" }
        if !summary.isEnabled { return "Off — no next time" }
        if summary.workflow.problem != nil { return "Never, until the file is fixed" }
        if summary.isUnapproved { return "No next time until you approve it" }
        if summary.overLimit != nil { return "Over the limit — no next time" }
        let due = summary.nextFireAtByTrigger.indices.contains(index)
            ? summary.nextFireAtByTrigger[index]
            : (summary.workflow.schedules.count == 1 ? summary.nextFireAt : nil)
        guard let due else { return "No next time" }
        return "Next \(due.formatted(.relative(presentation: .named)))\n"
            + due.formatted(date: .abbreviated, time: .shortened)
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
            .disabled(workflow.mode == .triggering || workflow.settingsLocked || model.isStale)
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
        workflow.settings.runtimeID ?? RuntimeCatalog.defaultRuntime.id
    }

    /// The runtime, from the catalog: which runtimes exist is the app's to know. A
    /// value the catalog does not hold is shown and marked, because that workflow is
    /// refusing every fire on it (FR-009).
    private func runtimeRow(_ summary: WorkflowSummary) -> some View {
        let named = summary.workflow.settings.runtimeID
        let fallback = RuntimeCatalog.defaultRuntime
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

    // MARK: Labels (#142)

    /// The labels each run's agent gets, in the tag input sessions use; each change
    /// writes `labels:` in the file through the Mac.
    private func labels(_ summary: WorkflowSummary) -> some View {
        let labels = summary.workflow.settings.labels
        return VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Labels")
            VStack(alignment: .leading, spacing: 6) {
                LabelTagField(labels: labels.map { SessionLabel(value: $0, owner: .person) },
                              suggestions: model.labelSuggestions(in: summary.folder),
                              add: { values in setLabels(summary, labels + values) },
                              remove: { value in
                                  setLabels(summary, labels.filter { SessionLabelPolicy.key($0) != SessionLabelPolicy.key(value) })
                              })
                note(summary.workflow.labelsNote)
            }
            .padding(14)
            .paperRaised(in: RoundedRectangle(cornerRadius: 18))
            .disabled(summary.workflow.settingsLocked || model.isStale)
        }
    }

    /// Which computers run it (#317), under the names already on screen.
    private func hostsSection(_ summary: WorkflowSummary) -> some View {
        WorkflowHostsSection(choices: model.workflowHostChoices,
                             hosts: summary.workflow.hosts ?? [],
                             locked: summary.workflow.settingsLocked || model.isStale) { next in
            Task { await model.setWorkflowSettings(summary, summary.workflow.settings, hosts: next) }
        }
    }

    private func setLabels(_ summary: WorkflowSummary, _ labels: [String]) {
        Task { await model.setWorkflowSettings(summary, summary.workflow.settings, labels: labels) }
    }

    // MARK: The rest of the file (#142)

    /// Front-matter keys this version does not know, with their values, in grey: a key
    /// from a later version asks nothing of anyone.
    @ViewBuilder
    private func unknownKeys(_ workflow: Workflow) -> some View {
        if !workflow.unknownFields.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
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

    // MARK: What it has run

    /// The agents it started, newest first, as the project page draws them — each a
    /// tap from its conversation, and back comes here. Three to begin with.
    private func runs(_ workflow: Workflow) -> some View {
        let started = model.work.workflowRuns(workflow.workflowID, in: workflow.folder)
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
}

/// When a workflow page fetches its runs: opened, paged, or a run arrived.
private struct RunsAsk: Equatable {
    var workflowID: Workflow.ID
    var shown: Int
}
