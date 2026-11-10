import AgentsKitCore
import SwiftUI

/// The words of the Remote's Project Settings page.
enum RemoteProjectSettingsWords {
    static let title = "Project Settings"
    static let menuItem = "Project Settings…"
    static let folder = "Folder"
    static let missing = "Folder is missing"
    static let machine = "Machine"
    static let spent = "Spent"
    static let nothingPriced = "Nothing priced yet"
    static func spentSince(_ total: String) -> String { "\(total) since it was added" }
    static func unmeasured(_ sessions: Int) -> String {
        let counted = sessions == 1 ? "1 session" : "\(sessions) sessions"
        return "\(counted) ran on a runtime that reports no price, so this is a minimum."
    }
    /// What the Mac and the web page keep (#2798): the project's name, owner and folders, its
    /// tools, Agent Configuration, and the folder's disk space.
    static let elsewhere = "Open Project Settings on your Mac or the web page to change the project's name, "
        + "folders and tools, its Agent Configuration, and the folder's Disk Space."
    static func writtenIn(_ path: String, on machine: String) -> String {
        "Written in \(path) on \(machine). Commit .agents so that the project's other folders get it."
    }
}

/// Project Settings… from a folder's menu, asked at the scene's root as Move to Machine… is:
/// the menu, and perhaps its row, are gone by now.
struct ProjectSettingsAsk: ViewModifier {
    @Environment(RemoteModel.self) private var model

    func body(content: Content) -> some View {
        content.sheet(isPresented: Binding(get: { model.projectSettingsFolder != nil },
                                           set: { if !$0 { model.projectSettingsFolder = nil } })) {
            if let key = model.projectSettingsFolder {
                RemoteProjectSettings(key: key)
                    .environment(model)
            }
        }
    }
}

/// A project's settings on the iPhone and iPad: the parts a person changes while agents run
/// (Work at Once, Sessions, and the folder's own Policy), and the folder's General read-only.
/// The rest of the window's sheet (`ProjectSettingsSheet`, `FolderSettingsSheet`) is set-up
/// and stays on the Mac and the web page (#2798). The controls and words are the window's
/// (`Shared/UI/HelperLimitControls.swift`, `Shared/UI/FolderPolicyPane.swift`).
struct RemoteProjectSettings: View {
    @Environment(RemoteModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let key: FolderKey

    private var summary: DaemonAPI.FolderSummary? { model.folders.first { $0.key == key } }

    var body: some View {
        NavigationStack {
            Group {
                if let summary {
                    page(summary)
                } else {
                    ContentUnavailableView(RemoteProjectSettingsWords.missing, systemImage: "folder.badge.questionmark")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Paper.ground)
            .navigationTitle(summary?.name ?? RemoteProjectSettingsWords.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func page(_ summary: DaemonAPI.FolderSummary) -> some View {
        let limits = summary.folder.helperLimits ?? HelperLimits()
        let offline = model.hostIsOffline(summary.host)
        let save: (HelperLimits) async -> Void = { await model.setHelperLimits($0, for: summary.key) }
        return Form {
            // Changes made outside the app to its own files wait here (#502), as in General on the Mac.
            if let changes = summary.guardedChanges, !changes.isEmpty {
                Section {
                    ForEach(changes) { change in
                        GuardedChangeQuestion(change: change, key: summary.key)
                    }
                }
            }
            general(summary)
            // A section per control, its note under it, as iOS Settings has them.
            Section {
                LabeledContent(HelperLimitWords.helpers) {
                    Text(HelperLimitWords.helpersNow(running: summary.helperLimits.running,
                                                     notArchived: summary.helperLimits.notArchived))
                        .monospacedDigit()
                }
                if let mark = summary.helperLimitsSetBy { OrgPolicyLine(mark: mark) }
            } header: {
                Text(HelperLimitWords.workAtOnce)
            } footer: {
                Text(HelperLimitWords.helpersNote)
            }
            Section {
                HelperLimitPicker(limits: limits, key: \.queued, standard: HelperLimit.defaultQueued,
                                  maximum: HelperLimit.maximumQueued, title: HelperLimitWords.queued,
                                  disabled: offline, save: save)
            } footer: {
                Text(HelperLimitWords.queuedNote)
            }
            Section {
                HelperLimitSwitch(limits: limits, title: HelperLimitWords.allowanceSwitch, disabled: offline,
                                  isOn: { $0.continueWhenBack == true },
                                  set: { $0.continueWhenBack = $1 ? true : nil }, save: save)
            } footer: {
                Text(HelperLimitWords.allowanceNote)
            }
            Section {
                HelperLimitSwitch(limits: limits, title: HelperLimitWords.otherMachinesSwitch, disabled: offline,
                                  isOn: { $0.agentsMayStartOnMachines == true },
                                  set: { $0.agentsMayStartOnMachines = $1 ? true : nil }, save: save)
            } footer: {
                Text(HelperLimitWords.otherMachinesNote)
            }
            Section {
                HelperLimitSwitch(limits: limits, title: HelperLimitWords.archivedSwitch, disabled: offline,
                                  isOn: { $0.mayArchive },
                                  set: { $0.agentsMayArchive = $1 == HelperLimit.defaultAgentsMayArchive ? nil : $1 },
                                  save: save)
            } header: {
                Text(HelperLimitWords.sessions)
            } footer: {
                Text(HelperLimitWords.archivedNote)
            }
            Section {
                HelperLimitSwitch(limits: limits, title: HelperLimitWords.mergedSwitch, disabled: offline,
                                  isOn: { $0.archivesWhenMerged },
                                  set: { $0.archiveWhenMerged = $1 == HelperLimit.defaultArchiveWhenMerged ? nil : $1 },
                                  save: save)
            } footer: {
                Text(HelperLimitWords.mergedNote)
            }
            Section {
                NavigationLink {
                    FolderPolicyPane(summary: summary, host: model.hostClient(summary.host),
                                     revision: model.policyRevision, offline: offline)
                        .navigationTitle(PolicyLayersWords.title)
                        .navigationBarTitleDisplayMode(.inline)
                } label: {
                    Label(PolicyLayersWords.title, systemImage: PolicyLayersWords.symbol)
                }
            } footer: {
                Text(RemoteProjectSettingsWords.writtenIn(summary.folder.folder.path, on: model.machineName(summary.host))
                     + "\n\n" + RemoteProjectSettingsWords.elsewhere)
            }
        }
    }

    /// Folder Settings ▸ General, to read: where the folder is, on which machine, and what it
    /// has cost. Its Project picker and Archive Folder are the Mac's and the web page's (#2798).
    private func general(_ summary: DaemonAPI.FolderSummary) -> some View {
        Section {
            LabeledContent(RemoteProjectSettingsWords.folder) {
                Text(summary.folder.folder.path)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            if !summary.exists {
                Label(RemoteProjectSettingsWords.missing, systemImage: "exclamationmark.triangle")
                    .tinted(.failure)
            }
            LabeledContent(RemoteProjectSettingsWords.machine, value: model.machineName(summary.host))
            LabeledContent(RemoteProjectSettingsWords.spent) {
                if let total = Cost.total(of: summary.costToDate) {
                    Text(RemoteProjectSettingsWords.spentSince(total))
                } else {
                    Text(RemoteProjectSettingsWords.nothingPriced).foregroundStyle(.secondary)
                }
            }
        } footer: {
            if summary.unmeasuredAgents > 0 {
                Text(RemoteProjectSettingsWords.unmeasured(summary.unmeasuredAgents))
            }
        }
    }
}
