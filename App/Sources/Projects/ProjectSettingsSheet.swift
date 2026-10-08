import AgentsKitCore
import AppKit
import SwiftUI

/// The panes of Project Settings, in the order its rail lists them.
enum ProjectSettingsPane: String, Hashable, CaseIterable, Identifiable {
    case general, instructions, plugins, mcp, worktrees

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .instructions: "Instructions & skills"
        case .plugins: "Plugins"
        case .mcp: "MCP servers"
        case .worktrees: "Worktrees"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .instructions: "text.book.closed"
        case .plugins: "puzzlepiece.extension"
        case .mcp: "server.rack"
        case .worktrees: "arrow.triangle.branch"
        }
    }
}

/// One project's settings, as a sheet over the window (066, look/ frame C): a rail down
/// the left, the chosen pane beside it, and Done. The app's Settings window at a smaller
/// size, so a person who has found one has found the other.
///
/// A sheet rather than a page, because settings are somewhere you go to change a thing
/// and come back from — the project's sessions are still behind it when it closes. What
/// the project page used to say about the project itself (where it is, what it has cost)
/// is General's, since nobody acts on it from the page.
///
/// On a server only General is offered: the other panes read and write files in the
/// project's folder, which is not on this Mac.
struct ProjectSettingsSheet: View {
    @Environment(AppModel.self) private var model
    @Binding var pane: ProjectSettingsPane?

    static let size = CGSize(width: 760, height: 560)

    private var summary: DaemonAPI.ProjectSummary? { model.selectedProjectSummary }
    private var folder: URL? { model.selectedProject }
    private var isOnMac: Bool { model.selectedProjectKey?.host == .mac }

    private var panes: [ProjectSettingsPane] {
        isOnMac ? ProjectSettingsPane.allCases : [.general]
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
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) { content }
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(24)
                }
                HStack {
                    Spacer()
                    Button("Done") { pane = nil }
                        .buttonStyle(.paperProminent)
                        .keyboardShortcut(.defaultAction)
                }
                .padding(16)
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        // What the panes read: the worktrees are the prompt's list, asked for here in
        // case the sheet opened from a chat, where the prompt is somebody else's.
        .task(id: folder) {
            guard let folder else { return }
            await model.refreshPlugins(in: folder)
            if isOnMac, model.draftCwd != folder {
                model.draftCwd = folder
                await model.loadDraftOptions()
            }
        }
    }

    private var rail: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(summary?.name ?? "Project")
                .appText(.fine).fontWeight(.semibold).foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
            ForEach(panes) { each in
                let lit = chosen == each
                RailButton(lit: lit, label: each.title, selected: lit, action: { pane = each }) {
                    HStack(spacing: 8) {
                        Image(systemName: each.symbol)
                            .frame(width: 20)
                            .foregroundStyle(lit ? AnyShapeStyle(Paper.ground) : AnyShapeStyle(.secondary))
                            .accessibilityHidden(true)
                        Text(each.title)
                            .lineLimit(1)
                        Spacer()
                        if each == .plugins, waitingPlugins > 0 {
                            Circle().fill(StateTint.attention.style(or: .secondary)).frame(width: 7, height: 7)
                                .accessibilityLabel("Waiting for your OK")
                        }
                    }
                }
            }
            Spacer()
        }
        .padding(12)
        .frame(width: 220)
        .frame(maxHeight: .infinity)
        .background(Paper.sidebar)
    }

    private var waitingPlugins: Int {
        model.plugins(in: folder).filter { $0.awaitingApproval != nil }.count
    }

    @ViewBuilder
    private var content: some View {
        switch chosen {
        case .general:
            ProjectGeneralPane()
        case .instructions:
            if let folder {
                paneTitle(chosen, note: AgentsPlace.project(folder).explainer)
                AgentsInstructionsSection(place: .project(folder))
                AgentsSkillsSection(place: .project(folder))
            }
        case .plugins:
            if let folder {
                paneTitle(chosen)
                AgentsPluginsSection(place: .project(folder))
            }
        case .mcp:
            if let folder {
                paneTitle(chosen)
                ProjectMCPSection(place: .project(folder))
            }
        case .worktrees:
            paneTitle(chosen, note: "Worktrees the app made here outlive the sessions in them. This is where to be done with them.")
            WorktreesSection(folder: folder)
        }
    }

    @ViewBuilder
    private func paneTitle(_ pane: ProjectSettingsPane, note: String? = nil) -> some View {
        Text(pane.title)
            .appText(.title).fontWeight(.semibold)
        if let note {
            Text(note)
                .appText(.fine).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
        }
    }
}

/// The project itself: its name, where it is, what it has cost, and how many agents its
/// agents may start (#64).
private struct ProjectGeneralPane: View {
    @Environment(AppModel.self) private var model

    private var summary: DaemonAPI.ProjectSummary? { model.selectedProjectSummary }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(ProjectSettingsPane.general.title)
                .appText(.title).fontWeight(.semibold)
                .padding(.bottom, 18)
            if let summary {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 12) {
                    row("Name") { Text(summary.name).textSelection(.enabled) }
                    row("Folder") {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(ProjectPlace.path(summary.folder, on: summary.host))
                                .textSelection(.enabled)
                                .help(summary.folder.path)
                            if !summary.exists {
                                Label("Folder is missing", systemImage: "exclamationmark.triangle")
                                    .appText(.fine)
                                    .tinted(.failure)
                            } else if summary.host == .mac {
                                Button("Show in Finder") {
                                    model.reveal(summary.folder, on: summary.host)
                                }
                                .buttonStyle(.paper)
                                .appText(.fine)
                            }
                        }
                    }
                    row("Machine") { Text(model.hosts.label(summary.host)) }
                    row("Spent") { spent(summary) }
                    row("Helpers running") {
                        helperLimit(\.running, in: summary, default: HelperLimit.defaultRunning,
                                    upTo: min(HelperLimit.maximumRunning, summary.helperLimits.notArchived))
                    }
                    row("Helpers not archived") {
                        VStack(alignment: .leading, spacing: 6) {
                            helperLimit(\.notArchived, in: summary, default: HelperLimit.defaultNotArchived,
                                        upTo: HelperLimit.maximumNotArchived,
                                        from: summary.helperLimits.running)
                        }
                    }
                    row("Helpers queued") {
                        VStack(alignment: .leading, spacing: 6) {
                            helperLimit(\.queued, in: summary, default: HelperLimit.defaultQueued,
                                        upTo: HelperLimit.maximumQueued)
                            Text("How many agents that other agents started may be running at once, how "
                                 + "many may be kept until you archive them, and how many more may wait to "
                                 + "start, oldest first, when a place frees. Agents can't change these.")
                                .appText(.fine)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            // They go with the project (#126), so say where.
                            Text("These and Helpers archived are saved in .agents/project.json, a file in "
                                 + "this project you may commit.")
                                .appText(.fine)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    row("Helpers archived") {
                        VStack(alignment: .leading, spacing: 6) {
                            mayArchive(in: summary)
                            Text("An agent may archive only agents it started, once they've stopped working, "
                                 + "and never itself or your own sessions. You can bring any of them back.")
                                .appText(.fine)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    row("Low disk space") {
                        diskLine(\.lowGB, in: summary, default: DiskThresholds.defaultLowGB,
                                 choices: DiskThresholds.lowChoices)
                    }
                    row("Critical disk space") {
                        VStack(alignment: .leading, spacing: 6) {
                            diskLine(\.criticalGB, in: summary, default: DiskThresholds.defaultCriticalGB,
                                     choices: DiskThresholds.criticalChoices)
                            Text("When free space on the disk holding this project or its worktrees falls below "
                                 + "these, the window says so and machine.disk_low is raised for agents and workflows. "
                                 + "Low is also below \((summary.project.diskSpace ?? DiskThresholds()).effectiveLowPercent)% "
                                 + "of the disk. Saved in .agents/project.json.")
                                .appText(.fine)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .appText(.supporting)
                Divider().padding(.vertical, 20)
                Button("Archive Project") {
                    Task { await model.archiveProject(summary.key) }
                }
                .buttonStyle(.paper)
                .disabled(model.hosts.isOffline(summary.host))
                .help("Put this project away. Its sessions are kept; bring it back from Archived in the sidebar.")
            }
        }
    }

    private func row(_ label: String, @ViewBuilder value: () -> some View) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            value()
        }
    }

    /// One helper limit (#64) as a menu of the numbers it may be, its default marked and
    /// choosing it putting the project back to the default.
    private func helperLimit(_ key: WritableKeyPath<HelperLimits, Int?>, in summary: DaemonAPI.ProjectSummary,
                             default standard: Int, upTo maximum: Int, from minimum: Int = 1) -> some View {
        let kept = summary.project.helperLimits ?? HelperLimits()
        let current = kept[keyPath: key] ?? standard
        return Picker("", selection: Binding(get: { current }, set: { chosen in
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

    /// One disk space line (#195) as a menu of sizes, its default marked and choosing it
    /// putting the project back to the default. A size set by hand is offered too.
    private func diskLine(_ key: WritableKeyPath<DiskThresholds, Int?>, in summary: DaemonAPI.ProjectSummary,
                          default standard: Int, choices: [Int]) -> some View {
        let kept = summary.project.diskSpace ?? DiskThresholds()
        let current = kept[keyPath: key] ?? standard
        let offered = Set(choices + [current]).sorted()
        return Picker("", selection: Binding(get: { current }, set: { chosen in
            var lines = kept
            lines[keyPath: key] = chosen == standard ? nil : chosen
            Task { await model.setDiskSpace(lines, for: summary.key) }
        })) {
            ForEach(offered, id: \.self) { size in
                Text(size == standard ? "\(size) GB (default)" : "\(size) GB").tag(size)
            }
        }
        .labelsHidden()
        .fixedSize()
        .disabled(model.hosts.isOffline(summary.host))
    }

    /// Whether agents may archive the helpers they started (#120), beside the limits
    /// those places count against. Back to nil when it is the default again.
    private func mayArchive(in summary: DaemonAPI.ProjectSummary) -> some View {
        let kept = summary.project.helperLimits ?? HelperLimits()
        return Toggle("Agents may archive the helpers they started", isOn: Binding(get: { kept.mayArchive }, set: { on in
            var limits = kept
            limits.agentsMayArchive = on == HelperLimit.defaultAgentsMayArchive ? nil : on
            Task { await model.setHelperLimits(limits, for: summary.key) }
        }))
        .toggleStyle(.switch)
        .controlSize(.small)
        .disabled(model.hosts.isOffline(summary.host))
    }

    /// What this project has cost, in words that say how sure the figure is.
    ///
    /// `Cost.total(of:)` returns nil when nothing has been spent, and a zero would be a
    /// claim the app has not made, so nothing priced says so instead.
    @ViewBuilder
    private func spent(_ summary: DaemonAPI.ProjectSummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let total = Cost.total(of: summary.costToDate) {
                Text("\(total) since it was added")
            } else {
                Text("Nothing priced yet").foregroundStyle(.secondary)
            }
            if summary.unmeasuredAgents > 0 {
                let sessions = summary.unmeasuredAgents == 1 ? "1 session" : "\(summary.unmeasuredAgents) sessions"
                Text("\(sessions) ran on a runtime that reports no price, so this is a minimum.")
                    .appText(.fine)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A project's folder as a person writes it: `~/Agents` on this Mac, the full path on
/// a server, where `~` would be somebody else's home.
enum ProjectPlace {
    static func path(_ folder: URL, on host: HostID) -> String {
        let path = folder.path
        guard host == .mac else { return path }
        let home = RealHome.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}
