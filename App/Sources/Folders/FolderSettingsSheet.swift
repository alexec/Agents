import AgentsKitCore
import SwiftUI

/// The panes of Folder Settings (#3280, specs/3273-project-unit): only what belongs to one
/// directory on one machine. What every folder of the project shares is Project Settings'
/// (`ProjectSettingsSheet`).
enum FolderSettingsPane: String, Hashable, CaseIterable, Identifiable {
    case general, diskSpace, notCommitted

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .diskSpace: "Disk Space"
        case .notCommitted: "Not Committed"
        }
    }

    var symbol: String {
        switch self {
        case .general: "folder"
        case .diskSpace: "internaldrive"
        case .notCommitted: "eye.slash"
        }
    }
}

/// Which folder's Folder Settings are up, and at which pane.
struct FolderSettingsAsk: Hashable {
    var folder: FolderKey
    var pane: FolderSettingsPane = .general
}

/// One folder's settings, as a sheet over the window (#3280): the path, the machine and the
/// project it is in, its disk space lines and what in its `.agents` is not committed. Smaller than Project Settings,
/// with the same rail and Done, and a way to the project's.
struct FolderSettingsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(WindowRequests.self) private var requests
    @Binding var ask: FolderSettingsAsk?

    static let size = CGSize(width: 720, height: 460)

    private var summary: DaemonAPI.FolderSummary? { ask.flatMap { model.work.folder($0.folder) } }
    private var chosen: FolderSettingsPane { ask?.pane ?? .general }

    /// A folder's worktrees are on its machine's page (#3627), not here.
    private var panes: [FolderSettingsPane] { FolderSettingsPane.allCases }

    var body: some View {
        HStack(spacing: 0) {
            rail
            Divider()
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if let summary {
                            switch chosen {
                            case .general: FolderGeneralPane(summary: summary)
                            case .diskSpace: FolderDiskSpacePane(summary: summary)
                            case .notCommitted: FolderNotCommittedPane(summary: summary)
                            }
                        } else {
                            Text("This folder is not here any more.").foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(24)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                HStack {
                    Button(ProjectSettingsWords.menuItem) { openProjectSettings() }
                        .buttonStyle(.paper)
                        .disabled(summary == nil)
                    Spacer()
                    Button("Done") { ask = nil }
                        .buttonStyle(.paperProminent)
                        .keyboardShortcut(.defaultAction)
                }
                .padding(16)
            }
        }
        .frame(minWidth: Self.size.width, idealWidth: Self.size.width, maxWidth: .infinity,
               minHeight: Self.size.height, idealHeight: Self.size.height, maxHeight: .infinity)
        .presentationSizing(.fitted)
    }

    /// The project's settings, kept in this folder: the window shows this folder, so Project
    /// Settings reads and writes its `.agents`.
    private func openProjectSettings() {
        guard let summary else { return }
        if model.selectedFolderKey != summary.key { model.showFolder(summary.key) }
        requests.projectSettings = .general
        ask = nil
    }

    private var rail: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(summary?.name ?? ProjectSettingsWords.folderTitle)
                .appText(.fine).fontWeight(.semibold).foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
            ForEach(panes) { each in
                RailButton(lit: chosen == each, label: each.title, selected: chosen == each,
                           action: { ask?.pane = each }) {
                    HStack(spacing: 8) {
                        Image(systemName: each.symbol)
                            .frame(width: 20)
                            .foregroundStyle(chosen == each ? AnyShapeStyle(Paper.ground) : AnyShapeStyle(.secondary))
                            .accessibilityHidden(true)
                        Text(each.title).lineLimit(1)
                        Spacer()
                    }
                }
            }
            Spacer()
        }
        .padding(12)
        .frame(width: 200)
        .frame(maxHeight: .infinity)
        .background(Paper.sidebar)
    }
}

/// The folder itself: where it is, on which machine, the project it is in, and what it has
/// cost.
private struct FolderGeneralPane: View {
    @Environment(AppModel.self) private var model
    let summary: DaemonAPI.FolderSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsPaneTitle(title: FolderSettingsPane.general.title)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 12) {
                settingsRow("Folder") {
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
                settingsRow("Machine") { Text(model.hosts.label(summary.host)) }
                // What people work on, across machines (#2317).
                settingsRow(ProjectWords.title) {
                    ProjectPicker(control: model.controlRequests, summary: summary) { id in
                        await model.setProject(id, for: summary.key)
                    }
                }
                settingsRow("Spent") { spent }
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

    /// What this folder has cost, in words that say how sure the figure is.
    ///
    /// `Cost.total(of:)` returns nil when nothing has been spent, and a zero would be a
    /// claim the app has not made, so nothing priced says so instead.
    private var spent: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let total = Cost.total(of: summary.costToDate) {
                Text("\(total) since it was added")
            } else {
                Text("Nothing priced yet").foregroundStyle(.secondary)
            }
            if summary.unmeasuredAgents > 0 {
                let sessions = summary.unmeasuredAgents == 1 ? "1 session" : "\(summary.unmeasuredAgents) sessions"
                settingsNote("\(sessions) ran on a runtime that reports no price, so this is a minimum.")
            }
        }
    }
}

/// When the disk under this folder is low (#195): a line for low and one for critical.
private struct FolderDiskSpacePane: View {
    @Environment(AppModel.self) private var model
    let summary: DaemonAPI.FolderSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsPaneTitle(title: FolderSettingsPane.diskSpace.title)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 12) {
                settingsRow("Low disk space") {
                    diskLine(\.lowPercent, default: DiskThresholds.defaultLowPercent, choices: DiskThresholds.lowChoices)
                }
                settingsRow("Critical disk space") {
                    VStack(alignment: .leading, spacing: 6) {
                        diskLine(\.criticalPercent, default: DiskThresholds.defaultCriticalPercent,
                                 choices: DiskThresholds.criticalChoices)
                        settingsNote("When free space on the disk holding this folder or its worktrees falls below "
                                     + "these, as a percent of the disk, the machine's row and page say so and "
                                     + "machine.disk_low is raised for agents and workflows. Saved in .agents/folder.json.")
                    }
                }
            }
            .appText(.supporting)
        }
    }

    /// One disk space line (#195) as a menu of percents, its default marked and choosing it
    /// putting the folder back to the default. A percent set by hand is offered too.
    private func diskLine(_ key: WritableKeyPath<DiskThresholds, Int?>, default standard: Int,
                          choices: [Int]) -> some View {
        let kept = summary.folder.diskSpace ?? DiskThresholds()
        let current = kept[keyPath: key] ?? standard
        let offered = Set(choices + [current]).sorted()
        return Picker("", selection: Binding(get: { current }, set: { chosen in
            var lines = kept
            lines[keyPath: key] = chosen == standard ? nil : chosen
            Task { await model.setDiskSpace(lines, for: summary.key) }
        })) {
            ForEach(offered, id: \.self) { percent in
                Text(percent == standard ? "\(percent)% (default)" : "\(percent)%").tag(percent)
            }
        }
        .labelsHidden()
        .fixedSize()
        .disabled(model.hosts.isOffline(summary.host))
    }
}

/// What in this folder's `.agents` Git ignores (#3448): it stays on this machine, so the
/// project's other folders do not get it.
private struct FolderNotCommittedPane: View {
    @Environment(AppModel.self) private var model
    let summary: DaemonAPI.FolderSummary
    @State private var reading: DaemonAPI.NotCommittedResponse?
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsPaneTitle(title: FolderSettingsPane.notCommitted.title,
                              note: "What in this folder's .agents Git ignores. It stays on this machine: "
                                  + "the project's other folders do not get it.")
            if let problem {
                Text(problem).foregroundStyle(.secondary)
            } else if let reading {
                if !reading.isRepository {
                    Text("This folder is not in a Git repository, so nothing in its .agents is committed.")
                        .foregroundStyle(.secondary)
                } else if reading.paths.isEmpty {
                    Text("Git ignores nothing in this folder's .agents.").foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(reading.paths, id: \.self) { path in
                            Text(path)
                                .appText(.code)
                                .textSelection(.enabled)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(path)
                        }
                        if reading.more > 0 {
                            Text("and \(reading.more) more").foregroundStyle(.secondary)
                        }
                    }
                    .appText(.supporting)
                    if summary.host == .mac {
                        Button("Show .agents in Finder") {
                            model.reveal(summary.folder.folder.appending(path: ".agents"), on: summary.host)
                        }
                        .buttonStyle(.paper)
                        .appText(.fine)
                        .padding(.top, 14)
                    }
                }
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: summary.key) {
            do {
                reading = try await model.notCommitted(in: summary.key)
                problem = nil
            } catch {
                problem = model.describe(error)
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

extension View {
    /// Project Settings or Folder Settings, as one sheet over the window (#3280): Folder
    /// Settings… in Project Settings' Folders swaps one for the other without a second sheet.
    func settingsSheets(_ requests: WindowRequests) -> some View {
        sheet(isPresented: Binding(get: { requests.projectSettings != nil || requests.folderSettings != nil },
                                   set: { if !$0 { requests.projectSettings = nil; requests.folderSettings = nil } })) {
            Group {
                if requests.folderSettings != nil {
                    FolderSettingsSheet(ask: Binding(get: { requests.folderSettings },
                                                     set: { requests.folderSettings = $0 }))
                } else {
                    ProjectSettingsSheet(pane: Binding(get: { requests.projectSettings },
                                                       set: { requests.projectSettings = $0 }))
                }
            }
            .environment(requests)
            .paperSheet()
        }
    }
}
