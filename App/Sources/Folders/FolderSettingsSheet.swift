import AgentsKitCore
import AppKit
import SwiftUI

/// The panes of Folder Settings: General, then the Agent Configuration pages that Settings
/// has too (#754), which the rail shows as one row with the pages listed in its pane (#1076). Worktrees moved to Activity
/// (#790): they change on their own, and settings are what a person sets.
enum FolderSettingsPane: String, Hashable, CaseIterable, Identifiable {
    case general, overview, instructions, skills, personas, workflows, mcp, plugins, other

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
        case .general: nil
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
        default: page?.title ?? ""
        }
    }

    var symbol: String { "gearshape" }
}

/// One folder's settings, as a sheet over the window (066, look/ frame C): a rail down
/// the left, the chosen pane beside it, and Done. The app's Settings window at a smaller
/// size, so a person who has found one has found the other.
///
/// A sheet rather than a page, because settings are somewhere you go to change a thing
/// and come back from — the folder's sessions are still behind it when it closes. What
/// the folder page used to say about the folder itself (where it is, what it has cost)
/// is General's, since nobody acts on it from the page.
///
/// On a server only General is offered: the other panes read and write files in the
/// folder, which is not on this Mac.
struct FolderSettingsSheet: View {
    @Environment(AppModel.self) private var model
    @Binding var pane: FolderSettingsPane?

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

    private var panes: [FolderSettingsPane] {
        isOnMac ? FolderSettingsPane.allCases : [.general]
    }

    private var chosen: FolderSettingsPane {
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
                    Button("Done") { pane = nil }
                        .buttonStyle(.paperProminent)
                        .keyboardShortcut(.defaultAction)
                }
                .padding(16)
            }
        }
        // Resizable: a range rather than a fixed size, so the sheet can be dragged big
        // enough to show a whole pane, and the panes fill what it is given (#439).
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    private var rail: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(summary?.name ?? "Folder")
                .appText(.fine).fontWeight(.semibold).foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
            paneItem(.general, title: FolderSettingsPane.general.title, symbol: FolderSettingsPane.general.symbol,
                     lit: chosen == .general, waiting: !(summary?.guardedChanges ?? []).isEmpty)
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

    private func paneItem(_ each: FolderSettingsPane, title: String, symbol: String,
                          lit: Bool, waiting: Bool) -> some View {
        RailButton(lit: lit, label: title + (waiting ? ", waiting for your OK" : ""),
                   selected: lit, action: { pane = each }) {
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
                                   page: Binding(get: { page }, set: { pane = FolderSettingsPane($0) }),
                                   waiting: waitingPlugins > 0 ? [.plugins] : [],
                                   refresh: { await refreshSnapshot() })
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    FolderGeneralPane()
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(24)
            }
        }
    }

    @ViewBuilder
    private func paneTitle(_ pane: FolderSettingsPane, note: String? = nil) -> some View {
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

/// The folder itself: its name, where it is, what it has cost, and how many agents its
/// agents may start (#64).
private struct FolderGeneralPane: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private var summary: DaemonAPI.FolderSummary? { model.selectedFolderSummary }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(FolderSettingsPane.general.title)
                .appText(.title).fontWeight(.semibold)
                .padding(.bottom, 18)
            if let summary {
                // Changes made outside the app to its own files wait here (#502).
                ForEach(summary.guardedChanges ?? []) { change in
                    GuardedChangeQuestion(change: change, key: summary.key, leaving: { dismiss() })
                        .padding(.bottom, 18)
                }
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 12) {
                    row("Name") { Text(summary.name).textSelection(.enabled) }
                    row("Folder") {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(FolderPlace.path(summary.folder.folder, on: summary.host))
                                .textSelection(.enabled)
                                .help(summary.folder.folder.path)
                            if !summary.exists {
                                Label("Folder is missing", systemImage: "exclamationmark.triangle")
                                    .appText(.fine)
                                    .tinted(.failure)
                            } else if summary.host == .mac {
                                Button("Show in Finder") {
                                    model.reveal(summary.folder.folder, on: summary.host)
                                }
                                .buttonStyle(.paper)
                                .appText(.fine)
                            }
                        }
                    }
                    row("Machine") { Text(model.hosts.label(summary.host)) }
                    row("Spent") { spent(summary) }
                    row("Helpers running") {
                        VStack(alignment: .leading, spacing: 6) {
                            helperLimit(\.running, in: summary, default: HelperLimit.defaultRunning,
                                        upTo: min(HelperLimit.maximumRunning, summary.helperLimits.notArchived),
                                        cap: helperCaps(summary)?.mostRunning)
                            // The organisation's cap is lower: it is the one used (#998).
                            if let mark = summary.helperLimitsSetBy { OrgPolicyLine(mark: mark) }
                        }
                    }
                    row("Helpers not archived") {
                        VStack(alignment: .leading, spacing: 6) {
                            helperLimit(\.notArchived, in: summary, default: HelperLimit.defaultNotArchived,
                                        upTo: HelperLimit.maximumNotArchived,
                                        from: summary.helperLimits.running,
                                        cap: helperCaps(summary)?.mostNotArchived)
                        }
                    }
                    row("Helpers queued") {
                        VStack(alignment: .leading, spacing: 6) {
                            helperLimit(\.queued, in: summary, default: HelperLimit.defaultQueued,
                                        upTo: HelperLimit.maximumQueued)
                            Text("How many sessions that other sessions started may be running at once, how "
                                 + "many may be kept until you archive them, and how many more may wait to "
                                 + "start, oldest first, when a place frees. Agents can't change these.")
                                .appText(.fine)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            // They go with the folder (#126), so say where.
                            Text("These and Helpers archived are saved in .agents/folder.json, a file in "
                                 + "this folder you may commit.")
                                .appText(.fine)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    row("Helpers archived") {
                        VStack(alignment: .leading, spacing: 6) {
                            mayArchive(in: summary)
                            Text("A session may archive only sessions it started, once their turn has ended, "
                                 + "and never your own sessions. Off, it asks you instead. You can bring any of them back.")
                                .appText(.fine)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    row("Allowance spent") {
                        VStack(alignment: .leading, spacing: 6) {
                            helpersContinue(in: summary)
                            Text("A session started by a session waits for the allowance and carries on "
                                 + "when it is back, as if you had chosen Continue. Off, it stops until you do.")
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
                            Text("When free space on the disk holding this folder or its worktrees falls below "
                                 + "these, the window says so and machine.disk_low is raised for agents and workflows. "
                                 + "Low is also below \((summary.folder.diskSpace ?? DiskThresholds()).effectiveLowPercent)% "
                                 + "of the disk. Saved in .agents/folder.json.")
                                .appText(.fine)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .appText(.supporting)
                Divider().padding(.vertical, 20)
                Button("Archive Folder") {
                    Task { await model.archiveFolder(summary.key) }
                }
                .buttonStyle(.paper)
                .disabled(model.hosts.isOffline(summary.host))
                .help("Put this folder away. Its sessions are kept; unarchive it from Archived in the sidebar.")
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
    /// choosing it putting the folder back to the default.
    /// The organisation's caps over a folder's helper limits (#998), as this Mac's host follows
    /// them. A server says its own when it refuses a number.
    private func helperCaps(_ summary: DaemonAPI.FolderSummary) -> DaemonAPI.PolicyHelpers? {
        summary.host == .mac ? model.policyState?.policy?.helpers : nil
    }

    private func helperLimit(_ key: WritableKeyPath<HelperLimits, Int?>, in summary: DaemonAPI.FolderSummary,
                             default standard: Int, upTo maximum: Int, from minimum: Int = 1,
                             cap: Int? = nil) -> some View {
        let kept = summary.folder.helperLimits ?? HelperLimits()
        let current = kept[keyPath: key] ?? standard
        return Picker("", selection: Binding(get: { current }, set: { chosen in
            var limits = kept
            limits[keyPath: key] = chosen == standard ? nil : chosen
            Task { await model.setHelperLimits(limits, for: summary.key) }
        })) {
            ForEach(Array(Swift.min(minimum, current)...Swift.max(maximum, current)), id: \.self) { number in
                // Above the organisation's cap: shown, not chosen (#998).
                Text(number == standard ? "\(number) (default)" : "\(number)").tag(number)
                    .disabled(cap.map { number > $0 } ?? false)
            }
        }
        .labelsHidden()
        .fixedSize()
        .disabled(model.hosts.isOffline(summary.host))
    }

    /// One disk space line (#195) as a menu of sizes, its default marked and choosing it
    /// putting the folder back to the default. A size set by hand is offered too.
    private func diskLine(_ key: WritableKeyPath<DiskThresholds, Int?>, in summary: DaemonAPI.FolderSummary,
                          default standard: Int, choices: [Int]) -> some View {
        let kept = summary.folder.diskSpace ?? DiskThresholds()
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

    /// Whether sessions may archive the sessions they started (#120, #638), beside the limits
    /// those places count against. Back to nil when it is the default again.
    private func mayArchive(in summary: DaemonAPI.FolderSummary) -> some View {
        let kept = summary.folder.helperLimits ?? HelperLimits()
        return Toggle("Sessions may archive the sessions they started", isOn: Binding(get: { kept.mayArchive }, set: { on in
            var limits = kept
            limits.agentsMayArchive = on == HelperLimit.defaultAgentsMayArchive ? nil : on
            Task { await model.setHelperLimits(limits, for: summary.key) }
        }))
        .toggleStyle(.switch)
        .controlSize(.small)
        .disabled(model.hosts.isOffline(summary.host))
    }

    /// Whether helpers carry on by themselves when a spent allowance is back (#1918). Off
    /// is the default, and back to nil.
    private func helpersContinue(in summary: DaemonAPI.FolderSummary) -> some View {
        let kept = summary.folder.helperLimits ?? HelperLimits()
        return Toggle("Helpers continue when the allowance is back", isOn: Binding(get: { kept.continueWhenBack == true }, set: { on in
            var limits = kept
            limits.continueWhenBack = on ? true : nil
            Task { await model.setHelperLimits(limits, for: summary.key) }
        }))
        .toggleStyle(.switch)
        .controlSize(.small)
        .disabled(model.hosts.isOffline(summary.host))
    }

    /// What this folder has cost, in words that say how sure the figure is.
    ///
    /// `Cost.total(of:)` returns nil when nothing has been spent, and a zero would be a
    /// claim the app has not made, so nothing priced says so instead.
    @ViewBuilder
    private func spent(_ summary: DaemonAPI.FolderSummary) -> some View {
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

/// A folder as a person writes it: `~/Agents` on this Mac, the full path on
/// a server, where `~` would be somebody else's home.
enum FolderPlace {
    static func path(_ folder: URL, on host: MachineRef) -> String {
        let path = folder.path
        guard host == .mac else { return path }
        let home = RealHome.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}
