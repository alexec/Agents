import AgentsKitCore
import SwiftUI

/// Settings ▸ General ▸ Archived agents (051, #398): how long archived agents are kept
/// before they are deleted.
///
/// The picker shows what the daemon holds, not what was last clicked. A change that would
/// delete agents at once comes back unapplied with what it would delete, and is only
/// applied when the person confirms, so a cancelled change simply leaves the picker where
/// it was (FR-011).
struct ArchiveSettingsSection: View {
    @Environment(AppModel.self) private var model
    @State private var asking: Asking?

    private struct Asking: Identifiable {
        let id = UUID()
        let settings: RetentionSettings
        let preview: DaemonAPI.DeletePreview
    }

    var body: some View {
        if let state = model.retentionState {
            Section {
                Text(DeletionWords.settingsSummary(archivedCount: state.archivedCount,
                                                   archivedBytes: state.archivedBytes,
                                                   settings: state.settings))
                    .appText(.reading)
                Picker("Delete archived agents after", selection: keepFor(in: state)) {
                    ForEach(RetentionSettings.KeepFor.allCases, id: \.self) { keep in
                        Text(DeletionWords.keepForLabel(keep)).tag(keep)
                    }
                }
            } header: {
                Text("Archived agents")
            } footer: {
                Text("An archived agent is deleted this long after it was archived: its conversation and "
                     + "record are removed. Nothing is deleted on the day it was archived, and an agent "
                     + "whose worktree still has work in it is kept until that work is committed and merged."
                     + (model.hosts.isEmpty ? "" : " Each server keeps to the same setting."))
            }
            .paperListRow()
            // Held while open (#101): a later change's answer waits for this one.
            .heldAlert({ _ in "Delete archived agents now?" }, item: { asking },
                       dismiss: { if asking?.id == $0.id { asking = nil } }) { ask in
                Button("Delete", role: .destructive) {
                    Task { _ = await model.setRetention(ask.settings, confirmed: true) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { ask in
                Text(DeletionWords.confirmSettings(count: ask.preview.count, bytes: ask.preview.bytes))
            }
        }
    }

    /// The setting, read from the daemon's state and changed through it.
    private func keepFor(in state: DaemonAPI.RetentionState) -> Binding<RetentionSettings.KeepFor> {
        Binding(get: { state.settings.keepFor }, set: { value in
            let settings = RetentionSettings(keepFor: value)
            Task {
                guard let result = await model.setRetention(settings, confirmed: false),
                      !result.applied, let preview = result.wouldDelete else { return }
                asking = Asking(settings: settings, preview: preview)
            }
        })
    }
}
