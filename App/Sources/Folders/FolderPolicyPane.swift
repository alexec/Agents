import AgentsKitCore
import SwiftUI

/// Folder Settings ▸ Policy (#2957, FR-022, frame D): the folder's own layer, kept in
/// `.agents/policy.json` and committed with its code. Each row starts at **Same as yours**
/// with your value; a value looser than yours is dimmed in its menu, and one kept in the file
/// above yours says "Capped by yours". A change made outside the app that loosens a rule waits
/// here for **Allow**. The machine resolves the layers (`policy/effective`) and keeps the file
/// (`policy/folder`, `policy/setFolder`). The web page's is the folder list in
/// `Web/src/views/settings/AgentsPolicy.tsx`.
struct FolderPolicyPane: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let summary: DaemonAPI.FolderSummary

    /// The rules for an agent in this folder, every layer resolved, with the cap above it.
    @State private var effective: DaemonAPI.EffectivePolicy?
    /// Your own effective rules, outside any folder: what "Same as yours" names.
    @State private var yours: DaemonAPI.EffectivePolicy?
    @State private var layer: DaemonAPI.PolicyFolderState?
    @State private var problem: String?
    @State private var isSaving = false

    private var host: DaemonClient { model.client(for: summary.host) }
    private var folder: String { summary.folder.folder.absoluteString }

    private struct Reload: Hashable {
        var folder: String
        var revision: Int
        var waiting: [GuardedChange]
    }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(PolicyLayersWords.title).appText(.title).fontWeight(.semibold)
                    Text(PolicyLayersWords.folderIntro)
                        .appText(.fine).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let problem {
                        Text(problem).appText(.fine).tinted(.failure)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let invalid = layer?.invalid {
                        Text(invalid).appText(.fine).tinted(.failure)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .paperListRow()
            // A change from outside the app that loosens a rule waits for your OK (FR-016).
            if let pending = layer?.pending {
                Section {
                    GuardedChangeQuestion(change: pending, key: summary.key, leaving: { dismiss() })
                }
                .paperListRow()
            }
            if let effective, let layer {
                ForEach(PolicyLayersWords.Section.allCases, id: \.self) { section in
                    Section {
                        ForEach(PolicyLayersWords.rows(in: section)) { row in
                            PolicyRuleRow(row: row, rule: effective.rules.first { $0.rule == row.rule },
                                          yours: PolicyLayersWords.value(layer.rules, row.rule),
                                          editable: !isSaving && !model.hosts.isOffline(summary.host),
                                          yourValue: yours?.rules.first { $0.rule == row.rule }?.words ?? row.unset) { value in
                                Task { await save(row.rule, value) }
                            }
                        }
                    } header: {
                        Text(section.title)
                    } footer: {
                        if section == .tools {
                            Text(PolicyLayersWords.toolsFoot).appText(.fine).foregroundStyle(.secondary)
                        }
                    }
                    .paperListRow()
                }
            } else if problem == nil {
                Text("Loading…").appText(.supporting).foregroundStyle(.secondary).paperListRow()
            }
        }
        .paperForm()
        .task(id: Reload(folder: folder, revision: model.policyRevision, waiting: summary.guardedChanges ?? [])) { await load() }
    }

    private func load() async {
        do {
            effective = try await host.call(DaemonAPI.Method.policyEffective, DaemonAPI.PolicyEffectiveRequest(folder: folder),
                                            returning: DaemonAPI.EffectivePolicy.self)
            yours = try await host.call(DaemonAPI.Method.policyEffective, DaemonAPI.PolicyEffectiveRequest(),
                                        returning: DaemonAPI.EffectivePolicy.self)
            layer = try await host.call(DaemonAPI.Method.policyFolder, DaemonAPI.PolicyFolderRequest(folder: folder),
                                        returning: DaemonAPI.PolicyFolderState.self)
            problem = nil
        } catch {
            problem = PeopleWords.refusal(error)
        }
    }

    private func save(_ rule: String, _ value: JSONValue?) async {
        guard let layer else { return }
        isSaving = true
        defer { isSaving = false }
        let rules = PolicyLayersWords.setting(layer.rules, rule, to: value)
        do {
            _ = try await host.call(DaemonAPI.Method.policySetFolder,
                                    DaemonAPI.SetFolderPolicyRequest(folder: folder, rules: rules),
                                    returning: DaemonAPI.PolicyRules.self)
            problem = nil
        } catch {
            problem = PeopleWords.refusal(error)
        }
        await load()
    }
}
