import AgentsKitCore
#if !AGENTS_STORE
import AgentsKit
#endif
import SwiftUI

/// Settings ▸ General ▸ Archived agents (051): how long archived agents are kept, and how
/// much space they may take, before the oldest are retired.
///
/// The pickers show what the daemon holds, not what was last clicked. A change that
/// would retire agents at once comes back unapplied with what it would retire, and is
/// only applied when the person confirms, so a cancelled change simply leaves the
/// picker where it was (FR-011).
struct ArchiveSettingsSection: View {
    @Environment(AppModel.self) private var model
    @State private var asking: Asking?

    private struct Asking: Identifiable {
        let id = UUID()
        let settings: RetentionSettings
        let preview: DaemonAPI.RetirePreview
    }

    var body: some View {
        if let state = model.retentionState {
            Section {
                Text(RetirementWords.settingsSummary(archivedCount: state.archivedCount,
                                                     archivedBytes: state.archivedBytes,
                                                     settings: state.settings))
                    .appText(.reading)
                Picker("Keep archived agents", selection: binding(\.keepFor, in: state)) {
                    ForEach(RetentionSettings.KeepFor.allCases, id: \.self) { keep in
                        Text(RetirementWords.keepForLabel(keep)).tag(keep)
                    }
                }
                Picker("Up to", selection: binding(\.cap, in: state)) {
                    ForEach(RetentionSettings.Cap.allCases, id: \.self) { cap in
                        Text(RetirementWords.capLabel(cap)).tag(cap)
                    }
                }
                if let over = state.overCap {
                    Label(RetirementWords.overCapSentence(over, cap: state.settings.cap),
                          systemImage: "exclamationmark.circle")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Archived agents")
            } footer: {
                Text("After this long, or once archived agents take more than this, the oldest are "
                     + "retired: the conversation is deleted and a short record of who the agent was "
                     + "is kept. Nothing is retired on the day it was archived, and an agent whose "
                     + "worktree still has work in it is kept until that work is committed and merged."
                     + (model.hosts.isEmpty ? "" : " Each server keeps to the same settings."))
            }
            .paperListRow()
            .alert("Retire archived agents now?", isPresented: Binding(get: { asking != nil },
                                                                       set: { if !$0 { asking = nil } }),
                   presenting: asking) { ask in
                Button("Retire", role: .destructive) {
                    Task { _ = await model.setRetention(ask.settings, confirmed: true) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { ask in
                Text(RetirementWords.confirmSettings(count: ask.preview.count, bytes: ask.preview.bytes,
                                                     upTo: ask.preview.upTo))
            }
        }
    }

    /// One setting, read from the daemon's state and changed through it.
    private func binding<Value>(_ key: WritableKeyPath<RetentionSettings, Value>,
                                in state: DaemonAPI.RetentionState) -> Binding<Value> {
        Binding(get: { state.settings[keyPath: key] }, set: { value in
            var settings = state.settings
            settings[keyPath: key] = value
            Task {
                guard let result = await model.setRetention(settings, confirmed: false),
                      !result.applied, let preview = result.wouldRetire else { return }
                asking = Asking(settings: settings, preview: preview)
            }
        })
    }
}
