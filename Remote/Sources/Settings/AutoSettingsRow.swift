import AgentsKitCore
import SwiftUI

/// Settings ▸ Agent Runtimes ▸ Auto on the phone and iPad (#2658, Story 6): the same order,
/// Include switches and Mappings as the Mac's, kept on the Mac's host. The Mappings show one
/// runtime at a time, its values as rows, as a phone is narrow.
struct AutoSettingsRow: View {
    var body: some View {
        SettingsPageLink(LevelWords.auto, systemImage: "wand.and.stars") { AutoSettingsPage() }
    }
}

private struct AutoSettingsPage: View {
    @Environment(RemoteModel.self) private var model
    @State private var shown: String?

    private var order: [String] {
        let listed = model.autoMappings.runtimeIDs
        return listed.isEmpty ? model.runtimes(on: .mac).map(\.runtime.id) : listed
    }

    var body: some View {
        Section {
            ForEach(order, id: \.self) { runtimeID in
                let status = model.runtimes(on: .mac).first { $0.runtime.id == runtimeID }
                Toggle(isOn: Binding(get: { !model.autoSettings.excluded.contains(runtimeID) }, set: { on in
                    Task { await model.setAutoSettings(model.autoSettings.including(runtimeID, on)) }
                })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(PromptWords.runtimeName(runtimeID))
                        Text(LevelWords.state(status, allowances: model.runtimeAllowances))
                            .appText(.supporting)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityLabel("\(LevelWords.include) \(PromptWords.runtimeName(runtimeID))")
            }
            .onMove { from, to in
                var ids = order
                ids.move(fromOffsets: from, toOffset: to)
                var s = model.autoSettings
                s.order = ids
                Task { await model.setAutoSettings(s) }
            }
        } header: {
            HStack {
                Text(LevelWords.runtimesTitle)
                Spacer()
                EditButton().appText(.supporting)
            }
        } footer: {
            Text(LevelWords.runtimesFooter)
        }
        .paperListRow()
        Section {
            Picker(LevelWords.runtimeField, selection: Binding(get: { shown ?? order.first ?? "" }, set: { shown = $0 })) {
                ForEach(order, id: \.self) { Text(PromptWords.runtimeName($0)).tag($0) }
            }
        } header: {
            Text(LevelWords.mappingsTitle)
        } footer: {
            Text(LevelWords.mappingsFooter.replacingOccurrences(of: "Click", with: "Tap"))
        }
        .paperListRow()
        let runtimeID = shown ?? order.first ?? ""
        ForEach(AutoField.allCases, id: \.self) { field in
            Section(LevelWords.field(field)) {
                ForEach(LevelWords.levels(field), id: \.self) { level in
                    cellRow(runtimeID, field, level)
                }
            }
            .paperListRow()
        }
        .task { await model.refreshAuto() }
    }

    private func cellRow(_ runtimeID: String, _ field: AutoField, _ level: String) -> some View {
        let cell = model.autoMappings.cell(runtimeID, field, level)
        let choices = model.autoMappings.choices.filter { $0.runtimeID == runtimeID && $0.field == field }
        let mark = cell.map { [LevelWords.mark($0.mark), $0.note].compactMap { $0 }.joined(separator: ": ") } ?? ""
        return Menu {
            ForEach(choices, id: \.self) { choice in
                Button {
                    set(runtimeID, field, level, choice.native)
                } label: {
                    if choice.native == cell?.native {
                        Label(choice.words, systemImage: "checkmark")
                    } else {
                        Text(choice.words)
                    }
                }
            }
            if cell?.mark == .yours {
                Button(LevelWords.reset, role: .destructive) { set(runtimeID, field, level, nil) }
            }
        } label: {
            LabeledContent {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(cell?.words ?? "—").foregroundStyle(.primary)
                    Text(mark).appText(.supporting)
                        .foregroundStyle(cell?.mark == .dropped ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                }
            } label: {
                Text(LevelWords.level(field, level))
            }
            .appText(.reading)
        }
        .disabled(choices.isEmpty)
        .accessibilityLabel("\(LevelWords.level(field, level)), \(cell?.words ?? "")")
    }

    private func set(_ runtimeID: String, _ field: AutoField, _ level: String, _ native: NativeSetting?) {
        let s = model.autoSettings.overriding(runtimeID, field, level, with: native)
        Task { await model.setAutoSettings(s) }
    }
}
