import AgentsKitCore
import AppKit
import SwiftUI

/// The panes of Project Settings (#3280, specs/3273-project-unit): what every folder of the
/// project shares, because it is in the repository's `.agents` and travels with Git. General,
/// Tools, Work at once, Sessions, Policy, then the Agent Configuration pages that Settings has
/// too (#754), which the rail shows as one row with the pages listed in its pane (#1076).
/// What is only one folder's (disk space, worktrees) is Folder Settings' (`FolderSettingsSheet`).
enum ProjectSettingsPane: String, Hashable, CaseIterable, Identifiable {
    case general
    /// The Tasks, Code review and CI slots (#2669), and the folder's other connector slots.
    case tools
    /// How many helpers may run, wait and stay (#64).
    case workAtOnce
    /// Which sessions are archived by themselves (#120, #2886).
    case sessions
    /// The folder's own layer of the policy (#2957, FR-022): `.agents/policy.json`.
    case policy
    case overview, instructions, skills, personas, workflows, mcp, plugins, other

    var id: String { rawValue }

    init(_ page: AgentConfigurationPage) {
        switch page {
        case .overview: self = .overview
        case .instructions: self = .instructions
        case .skills: self = .skills
        case .personas: self = .personas
        case .workflows: self = .workflows
        case .mcp: self = .mcp
        case .plugins: self = .plugins
        case .other: self = .other
        }
    }

    /// The Agent Configuration page it is, if it is one.
    var page: AgentConfigurationPage? {
        switch self {
        case .general, .tools, .workAtOnce, .sessions, .policy: nil
        case .overview: .overview
        case .instructions: .instructions
        case .skills: .skills
        case .personas: .personas
        case .workflows: .workflows
        case .mcp: .mcp
        case .plugins: .plugins
        case .other: .other
        }
    }

    var title: String {
        switch self {
        case .general: "General"
        case .tools: "Tools"
        case .workAtOnce: "Work at Once"
        case .sessions: "Sessions"
        case .policy: PolicyLayersWords.title
        default: page?.title ?? ""
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .tools: "hammer"
        case .workAtOnce: "square.stack.3d.up"
        case .sessions: "archivebox"
        case .policy: PolicyLayersWords.symbol
        default: "gearshape"
        }
    }

    /// The panes before Agent Configuration, in the rail's order.
    static let rail: [ProjectSettingsPane] = [.general, .tools, .workAtOnce, .sessions, .policy]
}

/// A project's settings, as a sheet over the window (066, look/ frame C; #3280): a rail down
/// the left, the chosen pane beside it, and Done. The app's Settings window at a smaller
/// size, so a person who has found one has found the other.
///
/// The settings are kept in one folder of the project: the folder it was opened on. The
/// files are in the repository's `.agents`, so the person commits them and the project's
/// other folders get them; General says which folder that is.
///
/// On a server the Agent Configuration pages are not offered: they read and write files in
/// the folder, which is not on this Mac.
struct ProjectSettingsSheet: View {
    @Environment(AppModel.self) private var model
    @Binding var pane: ProjectSettingsPane?

    /// The smallest it can be dragged to, and where it opens the first time (#439).
    /// Wide enough for the rail, Agent Configuration's page list and a page (#1076).
    static let size = CGSize(width: 900, height: 560)

    /// The size it was last left at, so it opens as the person left it.
    @AppStorage("folderSettingsWidth", store: WindowDefaults.store) private var width = Double(Self.size.width)
    @AppStorage("folderSettingsHeight", store: WindowDefaults.store) private var height = Double(Self.size.height)

    private var summary: DaemonAPI.FolderSummary? { model.selectedFolderSummary }
    private var folder: URL? { model.selectedFolder }
    private var isOnMac: Bool { model.selectedFolderKey?.host == .mac }

    /// What the folder's `.agents` holds, for the Agent Configuration lines' counts and
    /// pages (#754). Read when the sheet opens, when a page is chosen, and when the app
    /// comes back to the front.
    @State private var snapshot: DaemonAPI.SharedSnapshot?
    /// A Skills, Personas or Workflows file has edits not saved: the rail and Done ask first (#2745).
    @State private var unsaved = false
    @State private var leaving: UnsavedLeave?
    /// The project, from the control plane: its name, owner and folders. Nil with none.
    @State private var project: DaemonAPI.Project?
    /// The owner's name, from `people/list`; nil when it could not be read.
    @State private var owner: String?

    private var panes: [ProjectSettingsPane] {
        isOnMac ? ProjectSettingsPane.allCases : ProjectSettingsPane.rail
    }

    private var chosen: ProjectSettingsPane {
        guard let pane, panes.contains(pane) else { return .general }
        return pane
    }

    var body: some View {
        HStack(spacing: 0) {
            rail
            Divider()
            VStack(spacing: 0) {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                HStack {
                    Spacer()
                    Button("Done") { $leaving.leave(unsaved: unsaved) { pane = nil } }
                        .buttonStyle(.paperProminent)
                        .keyboardShortcut(.defaultAction)
                }
                .padding(16)
            }
        }
        // Resizable: a range rather than a fixed size, so the sheet can be dragged big
        // enough to show a whole pane, and the panes fill what it is given (#439).
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .discardUnsavedQuestion($leaving)
        // Escape closes a sheet: with edits not saved, it asks as Done does.
        .interactiveDismissDisabled(unsaved)
        .onExitCommand { if unsaved { $leaving.leave(unsaved: unsaved) { pane = nil } } }
        .frame(minWidth: Self.size.width, idealWidth: max(width, Self.size.width),
               maxWidth: .infinity,
               minHeight: Self.size.height, idealHeight: max(height, Self.size.height),
               maxHeight: .infinity)
        .presentationSizing(.fitted)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
            width = size.width
            height = size.height
        }
        // What the panes read: the worktrees are the prompt's list, asked for here in
        // case the sheet opened from a chat, where the prompt is somebody else's.
        .task(id: folder) {
            guard let folder else { return }
            await model.refreshPlugins(in: folder)
            await refreshSnapshot()
            if isOnMac, model.draftCwd != folder {
                model.draftCwd = folder
                await model.loadDraftOptions()
            }
        }
        .task(id: summary?.project) { await loadProject() }
        .onChange(of: chosen) { _, now in
            if now.page != nil { Task { await refreshSnapshot() } }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refreshSnapshot() }
        }
    }

    private func refreshSnapshot() async {
        guard isOnMac, let folder else { snapshot = nil; return }
        if let fresh = await model.sharedSnapshot(folder: folder) { snapshot = fresh }
    }

    /// The project the folder is in, from `projects/list`; nil with no control plane, or one
    /// that could not be read, when General shows the folder's own name.
    private func loadProject() async {
        guard let control = model.controlRequests, let id = summary?.project else { project = nil; return }
        let listed = try? await control.call(DaemonAPI.Method.projectsList, DaemonAPI.Empty(),
                                             returning: DaemonAPI.ProjectList.self).projects
        project = listed?.first { $0.id == id }
        let people = try? await control.call(DaemonAPI.Method.peopleList, DaemonAPI.Empty(),
                                             returning: DaemonAPI.PeopleList.self).people
        owner = project.flatMap { project in people?.first { $0.id == project.owner }?.name }
    }

    private var rail: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(project?.name ?? summary?.name ?? ProjectWords.title)
                .appText(.fine).fontWeight(.semibold).foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
            ForEach(ProjectSettingsPane.rail) { each in
                paneItem(each, title: each.title, symbol: each.symbol, lit: chosen == each,
                         waiting: waiting(each))
            }
            if isOnMac {
                paneItem(chosen.page == nil ? .overview : chosen, title: SettingsPane.agentConfiguration.title,
                         symbol: SettingsPane.agentConfiguration.symbol,
                         lit: chosen.page != nil, waiting: waitingPlugins > 0)
            }
            Spacer()
        }
        .padding(12)
        .frame(width: 236)
        .frame(maxHeight: .infinity)
        .background(Paper.sidebar)
    }

    private func waiting(_ each: ProjectSettingsPane) -> Bool {
        let changes = summary?.guardedChanges ?? []
        switch each {
        case .general: return !changes.isEmpty
        case .policy: return changes.contains { $0.policy != nil }
        default: return false
        }
    }

    private func paneItem(_ each: ProjectSettingsPane, title: String, symbol: String,
                          lit: Bool, waiting: Bool) -> some View {
        RailButton(lit: lit, label: title + (waiting ? ", waiting for your OK" : ""),
                   selected: lit, action: { if !lit { $leaving.leave(unsaved: unsaved) { pane = each } } }) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .frame(width: 20)
                    .foregroundStyle(lit ? AnyShapeStyle(Paper.ground) : AnyShapeStyle(.secondary))
                    .accessibilityHidden(true)
                Text(title)
                    .lineLimit(1)
                Spacer()
                if waiting {
                    Circle().fill(StateTint.attention.style(or: .secondary)).frame(width: 7, height: 7)
                        .accessibilityHidden(true)
                }
            }
        }
    }

    private var waitingPlugins: Int {
        model.plugins(in: folder).filter { $0.awaitingApproval != nil }.count
    }

    @ViewBuilder
    private var content: some View {
        if let page = chosen.page, let folder {
            AgentConfigurationView(place: .folder(folder), snapshot: snapshot,
                                   page: Binding(get: { page }, set: { pane = ProjectSettingsPane($0) }),
                                   waiting: waitingPlugins > 0 ? [.plugins] : [],
                                   refresh: { await refreshSnapshot() }, unsaved: $unsaved)
        } else if chosen == .policy, let summary {
            FolderPolicyPane(summary: summary)
        } else if chosen == .tools, let summary {
            ProjectToolsPane(summary: summary)
        } else if let summary {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch chosen {
                    case .workAtOnce: ProjectWorkAtOncePane(summary: summary)
                    case .sessions: ProjectSessionsPane(summary: summary)
                    default: ProjectGeneralPane(summary: summary, project: project, owner: owner)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(24)
            }
        }
    }
}

/// A pane's title, and the line under it that says where its settings are kept.
struct SettingsPaneTitle: View {
    let title: String
    var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).appText(.title).fontWeight(.semibold)
            if let note {
                Text(note)
                    .appText(.fine)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.bottom, 18)
    }
}

/// One label and its value in a settings pane's grid.
@MainActor
func settingsRow(_ label: String, @ViewBuilder value: () -> some View) -> some View {
    GridRow {
        Text(label)
            .foregroundStyle(.secondary)
            .gridColumnAlignment(.trailing)
        value()
    }
}

/// The fine print under a setting.
@MainActor
func settingsNote(_ words: String) -> some View {
    Text(words)
        .appText(.fine)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
}

/// The words Project Settings and Folder Settings say about where a setting is kept.
enum ProjectSettingsWords {
    static let title = "Project Settings"
    static let menuItem = "Project Settings…"
    static let folderTitle = "Folder Settings"
    static let folderMenuItem = "Folder Settings…"

    /// Under each Project Settings pane: which folder keeps them, and what to do so the other
    /// folders get them.
    static func writtenIn(_ path: String, on machine: String) -> String {
        "Written in \(path) on \(machine). Commit .agents so that the project's other folders get it."
    }

    static let addOnAnotherMachine = "Add on Another Machine…"
    static let noOtherMachine = "Every machine you have has a folder of this project. Add a machine in Settings ▸ Machines first."
    static let notConnected = "not connected to this Mac"
    static let noControlPlane = "Connect to a control plane to see the project's folders on your other machines."
}

/// Where a Project Settings pane says its folder is: the path and the machine.
@MainActor
private func writtenIn(_ summary: DaemonAPI.FolderSummary, model: AppModel) -> String {
    ProjectSettingsWords.writtenIn(FolderPlace.path(summary.folder.folder, on: summary.host),
                                   on: model.hosts.label(summary.host))
}

/// The project itself: its name and owner, its folders on each machine, and what its merged
/// pull requests say (#2352).
private struct ProjectGeneralPane: View {
    @Environment(AppModel.self) private var model
    @Environment(WindowRequests.self) private var requests
    @Environment(\.dismiss) private var dismiss
    let summary: DaemonAPI.FolderSummary
    let project: DaemonAPI.Project?
    let owner: String?

    /// One folder of the project, as the Folders list shows it.
    private struct FolderLine: Identifiable {
        var machine: MachineRef
        var path: URL
        /// The folder as this window knows it, for its Folder Settings; nil when its machine
        /// is not one this Mac is connected to.
        var local: DaemonAPI.FolderSummary?
        var id: String { "\(machine.rawValue)|\(path.path)" }
    }

    /// The window's own folders of the project first, then what the control plane says of
    /// the others. Without a control plane, the folders here that name the project.
    private var lines: [FolderLine] {
        let mine = summary.project.map { id in model.liveFolders.filter { $0.project == id } }
            ?? [summary]
        var lines = mine.map { FolderLine(machine: $0.host, path: $0.folder.folder, local: $0) }
        for folder in project?.folders ?? [] {
            let path = folder.folder.standardizedFileURL
            let known = mine.contains { local in
                local.folder.folder.standardizedFileURL == path
                    && (local.host == folder.machine || (local.host == .mac && model.isOnThisMac(folder.machine)))
            }
            if !known { lines.append(FolderLine(machine: folder.machine, path: path, local: nil)) }
        }
        return lines
    }

    /// The machines Add on Another Machine… offers: this Mac and the servers that answer,
    /// without those that have a folder of the project already.
    private var otherMachines: [MachineRef] {
        let have = Set(lines.map(\.machine))
        return ([MachineRef.mac] + model.hosts.servers)
            .filter { !have.contains($0) && !model.hostUnreachable($0) && !($0 != .mac && model.isOnThisMac($0)) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsPaneTitle(title: ProjectSettingsPane.general.title, note: writtenIn(summary, model: model))
            // Changes made outside the app to its own files wait here (#502).
            ForEach(summary.guardedChanges ?? []) { change in
                GuardedChangeQuestion(change: change, key: summary.key, leaving: { dismiss() })
                    .padding(.bottom, 18)
            }
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 12) {
                settingsRow("Name") { Text(project?.name ?? summary.name).textSelection(.enabled) }
                if let owner {
                    settingsRow("Owner") { Text(owner).textSelection(.enabled) }
                }
                settingsRow("Folders") { folders }
                // What a merged pull request says it cost (#2352); an older host has no such setting.
                if model.host(summary.host, has: Capability.lineageComment1) {
                    settingsRow("Cost on pull requests") {
                        VStack(alignment: .leading, spacing: 6) {
                            prCostComment
                            settingsNote(PRCostComment.help + " Saved in .agents/folder.json.")
                        }
                    }
                }
            }
            .appText(.supporting)
        }
    }

    private var folders: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(lines) { line in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(machineName(line.machine))
                        .frame(minWidth: 80, alignment: .leading)
                    Text(FolderPlace.path(line.path, on: line.local?.host ?? line.machine))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(line.path.path)
                    Text(state(line))
                        .appText(.fine)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    if let local = line.local {
                        Button(ProjectSettingsWords.folderMenuItem) {
                            requests.folderSettings = FolderSettingsAsk(folder: local.key)
                            requests.projectSettings = nil
                        }
                        .buttonStyle(.paper)
                        .appText(.fine)
                    }
                }
            }
            Menu(ProjectSettingsWords.addOnAnotherMachine) {
                ForEach(otherMachines, id: \.self) { machine in
                    Button(machineName(machine)) { addFolder(on: machine) }
                }
            }
            .fixedSize()
            .disabled(otherMachines.isEmpty)
            .help(otherMachines.isEmpty ? ProjectSettingsWords.noOtherMachine
                  : "Choose a folder of this project on another machine")
            if model.controlRequests == nil {
                settingsNote(ProjectSettingsWords.noControlPlane)
            }
        }
    }

    private func machineName(_ machine: MachineRef) -> String {
        model.isOnThisMac(machine) ? model.hosts.label(.mac) : model.hosts.label(machine)
    }

    private func state(_ line: FolderLine) -> String {
        guard line.local != nil else { return model.hosts.isOffline(line.machine) ? "offline" : ProjectSettingsWords.notConnected }
        if line.local?.exists == false { return "missing" }
        return model.hostUnreachable(line.local?.host ?? line.machine) ? "offline" : "online"
    }

    /// The sheet goes, then the machine's Choose a folder opens, as File ▸ Add Folder has it.
    private func addFolder(on machine: MachineRef) {
        requests.projectSettings = nil
        Task { @MainActor in
            // A sheet opens only once the last one has gone.
            try? await Task.sleep(for: .milliseconds(400))
            requests.folderSheet = .chooseFolder(machine)
        }
    }

    /// What the host says on the folder's merged pull requests (#2352): off, the default, or
    /// the tokens and time, or the cost too.
    private var prCostComment: some View {
        let current = summary.folder.prCostComment ?? .off
        return Picker("", selection: Binding(get: { current }, set: { chosen in
            Task { await model.setPRCostComment(chosen, for: summary.key) }
        })) {
            ForEach(PRCostComment.allCases, id: \.self) { choice in
                Text(choice == .off ? "\(choice.words) (default)" : choice.words).tag(choice)
            }
        }
        .labelsHidden()
        .fixedSize()
        .disabled(model.hosts.isOffline(summary.host))
    }
}

/// The project's Tasks, Code review and CI slots (#2669), and the folder's other slots: the
/// folder's Connectors set-up (#1336), here as well as on its Connectors page.
private struct ProjectToolsPane: View {
    @Environment(AppModel.self) private var model
    let summary: DaemonAPI.FolderSummary
    @State private var adding: MCPServersView.CatalogueSearch?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if model.host(summary.host, has: Capability.connectorsSetup1) {
                    ConnectorSetupView(folder: summary.key, folderName: summary.name,
                                       addConnector: { adding = .init(words: $0, marketplace: $1) })
                } else {
                    Text(UpdateWords.hostNeedsUpdate).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(24)
        }
        .sheet(item: $adding) { search in
            AddMCPSheet(destination: .folder(folder: summary.folder.folder.path),
                        query: search.words, marketplace: search.marketplace,
                        onAdded: { Task { await model.refreshMCPHealth(summary.host) } })
        }
    }
}

/// How many helpers the project's sessions may have at once (#64): running and not archived
/// from the policy, queued, and what they may do by themselves.
private struct ProjectWorkAtOncePane: View {
    @Environment(AppModel.self) private var model
    let summary: DaemonAPI.FolderSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsPaneTitle(title: ProjectSettingsPane.workAtOnce.title, note: writtenIn(summary, model: model))
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 12) {
                // Rules of the policy now (#2957, FR-015, FR-023): what applies here, and where
                // to change it. Project Settings ▸ Policy sets this project's own.
                settingsRow("Helpers") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(summary.helperLimits.running) running, \(summary.helperLimits.notArchived) not archived")
                            .monospacedDigit()
                        if let mark = summary.helperLimitsSetBy { OrgPolicyLine(mark: mark) }
                        settingsNote("Set in Settings ▸ Agents ▸ Policy, or for this project in Policy. "
                                     + "They count across all the project's folders, on every machine. A lead doesn't count; "
                                     + "the sessions it starts do.")
                    }
                }
                settingsRow("Helpers queued") {
                    VStack(alignment: .leading, spacing: 6) {
                        HelperLimitPicker(summary: summary, key: \.queued, standard: HelperLimit.defaultQueued,
                                          maximum: HelperLimit.maximumQueued)
                        settingsNote("How many more sessions that other sessions started may wait to start, "
                                     + "oldest first, when a place frees. Agents can't change this. "
                                     + "Saved in .agents/folder.json.")
                    }
                }
                settingsRow("Allowance spent") {
                    VStack(alignment: .leading, spacing: 6) {
                        HelperLimitSwitch(summary: summary, title: "Helpers continue when the allowance is back",
                                          isOn: { $0.continueWhenBack == true },
                                          set: { $0.continueWhenBack = $1 ? true : nil })
                        settingsNote("A session started by a session waits for the allowance and carries on "
                                     + "when it is back, as if you had chosen Continue. Off, it stops until you do.")
                    }
                }
                settingsRow("Other machines") {
                    VStack(alignment: .leading, spacing: 6) {
                        // Only the person sets it, here (#2928).
                        HelperLimitSwitch(summary: summary, title: "Agents may start sessions on my other machines without asking",
                                          isOn: { $0.agentsMayStartOnMachines == true },
                                          set: { $0.agentsMayStartOnMachines = $1 ? true : nil })
                        settingsNote("On, a session here may start a session on another of your machines without "
                                     + "asking you first. The new session's chat still says which session started it, "
                                     + "and from which machine. Off, it asks you each time.")
                    }
                }
            }
            .appText(.supporting)
        }
    }
}

/// Which sessions are put away by themselves (#120, #638, #2886).
private struct ProjectSessionsPane: View {
    @Environment(AppModel.self) private var model
    let summary: DaemonAPI.FolderSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsPaneTitle(title: ProjectSettingsPane.sessions.title, note: writtenIn(summary, model: model))
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 12) {
                settingsRow("Helpers archived") {
                    VStack(alignment: .leading, spacing: 6) {
                        HelperLimitSwitch(summary: summary, title: "Sessions may archive the sessions they started",
                                          isOn: { $0.mayArchive },
                                          set: { $0.agentsMayArchive = $1 == HelperLimit.defaultAgentsMayArchive ? nil : $1 })
                        settingsNote("A session may archive only sessions it started, once their turn has ended, "
                                     + "and never your own sessions. Off, it asks you instead. You can bring any of them back.")
                    }
                }
                settingsRow("Pull request merged") {
                    VStack(alignment: .leading, spacing: 6) {
                        HelperLimitSwitch(summary: summary, title: "Archive a session when its pull request merges",
                                          isOn: { $0.archivesWhenMerged },
                                          set: { $0.archiveWhenMerged = $1 == HelperLimit.defaultArchiveWhenMerged ? nil : $1 })
                        settingsNote("A session in a worktree is archived when the pull request from its branch merges, "
                                     + "once its turn has ended and its worktree has nothing uncommitted. Any other session "
                                     + "gets a line in its chat. This needs the github or gitlab connector in this folder. "
                                     + "You can bring any of them back.")
                    }
                }
            }
            .appText(.supporting)
        }
    }
}

/// One helper limit (#64) as a menu of the numbers it may be, its default marked and
/// choosing it putting the folder back to the default.
private struct HelperLimitPicker: View {
    @Environment(AppModel.self) private var model
    let summary: DaemonAPI.FolderSummary
    let key: WritableKeyPath<HelperLimits, Int?>
    let standard: Int
    let maximum: Int
    var minimum = 1

    var body: some View {
        let kept = summary.folder.helperLimits ?? HelperLimits()
        let current = kept[keyPath: key] ?? standard
        Picker("", selection: Binding(get: { current }, set: { chosen in
            var limits = kept
            limits[keyPath: key] = chosen == standard ? nil : chosen
            Task { await model.setHelperLimits(limits, for: summary.key) }
        })) {
            ForEach(Array(Swift.min(minimum, current)...Swift.max(maximum, current)), id: \.self) { number in
                Text(number == standard ? "\(number) (default)" : "\(number)").tag(number)
            }
        }
        .labelsHidden()
        .fixedSize()
        .disabled(model.hosts.isOffline(summary.host))
    }
}

/// One of the helpers' switches in `.agents/folder.json`, back to nil when it is the default.
private struct HelperLimitSwitch: View {
    @Environment(AppModel.self) private var model
    let summary: DaemonAPI.FolderSummary
    let title: String
    let isOn: (HelperLimits) -> Bool
    let set: (inout HelperLimits, Bool) -> Void

    var body: some View {
        let kept = summary.folder.helperLimits ?? HelperLimits()
        Toggle(title, isOn: Binding(get: { isOn(kept) }, set: { on in
            var limits = kept
            set(&limits, on)
            Task { await model.setHelperLimits(limits, for: summary.key) }
        }))
        .toggleStyle(.switch)
        .controlSize(.small)
        .disabled(model.hosts.isOffline(summary.host))
    }
}
