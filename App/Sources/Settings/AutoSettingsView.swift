import AgentsKitCore
import SwiftUI

/// Settings ▸ Agent Runtimes ▸ Auto (#2658, Story 3, Story 4): which runtimes Auto uses and in
/// what order, and what each shared value is on each runtime. The settings are the host's
/// (auto/state); a change goes to every machine (FR-017).
struct AutoSettingsView: View {
    @Environment(AppModel.self) private var model

    /// The runtimes in the person's order, as the Mappings list them.
    private var order: [String] {
        let listed = model.autoMappings.runtimeIDs
        return listed.isEmpty ? model.runtimes.map(\.id) : listed
    }

    var body: some View {
        Form {
            Section {
                ForEach(order, id: \.self) { runtimeID in
                    runtimeRow(runtimeID)
                }
                .onMove { from, to in
                    var ids = order
                    ids.move(fromOffsets: from, toOffset: to)
                    var s = model.autoSettings
                    s.order = ids
                    Task { await model.setAutoSettings(s) }
                }
            } header: {
                Text(LevelWords.runtimesTitle)
            } footer: {
                Text(LevelWords.runtimesFooter)
            }
            .paperListRow()
            ForEach(AutoField.allCases, id: \.self) { field in
                Section {
                    MappingTable(field: field, runtimeIDs: order)
                } header: {
                    Text(field == .model ? "\(LevelWords.mappingsTitle): \(LevelWords.field(field))" : LevelWords.field(field))
                } footer: {
                    if field == .model { Text(LevelWords.mappingsFooter) }
                }
                .paperListRow()
            }
        }
        .paperForm()
        .task {
            await model.refreshRuntimes()
            await model.refreshRuntimeAllowances()
            await model.refreshAuto()
        }
    }

    private func runtimeRow(_ runtimeID: String) -> some View {
        let status = model.runtimes.first { $0.id == runtimeID }
        let included = !model.autoSettings.excluded.contains(runtimeID)
        return HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Toggle(isOn: Binding(get: { included }, set: { on in
                Task { await model.setAutoSettings(model.autoSettings.including(runtimeID, on)) }
            })) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(PromptWords.runtimeName(runtimeID))
                    Text(LevelWords.state(status, allowances: model.runtimeAllowances))
                        .appText(.fine)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityLabel("\(LevelWords.include) \(PromptWords.runtimeName(runtimeID))")
        }
        .contextMenu {
            Button("Move Up") { move(runtimeID, by: -1) }.disabled(order.first == runtimeID)
            Button("Move Down") { move(runtimeID, by: 1) }.disabled(order.last == runtimeID)
        }
        .accessibilityAction(named: "Move Up") { move(runtimeID, by: -1) }
        .accessibilityAction(named: "Move Down") { move(runtimeID, by: 1) }
    }

    private func move(_ runtimeID: String, by step: Int) {
        var ids = order
        guard let i = ids.firstIndex(of: runtimeID), ids.indices.contains(i + step) else { return }
        ids.swapAt(i, i + step)
        var s = model.autoSettings
        s.order = ids
        Task { await model.setAutoSettings(s) }
    }
}

/// One field's table: a row for each runtime, a column for each value; each cell the
/// runtime's own setting, its mark, and a menu of the runtime's own choices (FR-014–FR-016).
private struct MappingTable: View {
    @Environment(AppModel.self) private var model
    let field: AutoField
    let runtimeIDs: [String]

    var body: some View {
        let levels = LevelWords.levels(field)
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
            GridRow {
                Text(LevelWords.runtimeField).appText(.fine).foregroundStyle(.secondary)
                ForEach(levels, id: \.self) { level in
                    Text(LevelWords.level(field, level)).appText(.fine).foregroundStyle(.secondary)
                }
            }
            Divider()
            ForEach(runtimeIDs, id: \.self) { runtimeID in
                GridRow(alignment: .firstTextBaseline) {
                    Text(PromptWords.runtimeName(runtimeID))
                    ForEach(levels, id: \.self) { level in
                        MappingCell(runtimeID: runtimeID, field: field, level: level)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

private struct MappingCell: View {
    @Environment(AppModel.self) private var model
    let runtimeID: String
    let field: AutoField
    let level: String

    var body: some View {
        let cell = model.autoMappings.cell(runtimeID, field, level)
        let choices = model.autoMappings.choices.filter { $0.runtimeID == runtimeID && $0.field == field }
        VStack(alignment: .leading, spacing: 1) {
            if let cell, !choices.isEmpty {
                Menu {
                    ForEach(choices, id: \.self) { choice in
                        Button {
                            set(choice.native)
                        } label: {
                            if choice.native == cell.native {
                                Label(choice.words, systemImage: "checkmark")
                            } else {
                                Text(choice.words)
                            }
                        }
                    }
                    if cell.mark == .yours {
                        Divider()
                        Button(LevelWords.reset) { set(nil) }
                    }
                } label: {
                    Text(cell.words).lineLimit(1)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .fixedSize()
                .accessibilityLabel("\(PromptWords.runtimeName(runtimeID)), \(LevelWords.level(field, level))")
                .accessibilityValue(cell.words)
            } else {
                Text(cell?.words ?? "—").lineLimit(1)
            }
            if let cell {
                Text(markLine(cell))
                    .appText(.fine)
                    .foregroundStyle(cell.mark == .dropped ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .lineLimit(2)
                    .help(cell.note ?? "")
            }
        }
        .appText(.fine)
    }

    private func markLine(_ cell: AutoMapping) -> String {
        let mark = cell.mark == .dropped ? "⚠︎ \(LevelWords.mark(cell.mark))" : LevelWords.mark(cell.mark)
        guard cell.mark != .notPossible, cell.mark != .dropped, let note = cell.note else {
            return cell.mark == .notPossible ? (cell.note ?? "") : mark
        }
        return note.hasPrefix(mark) ? note : "\(mark): \(note)"
    }

    private func set(_ native: NativeSetting?) {
        let s = model.autoSettings.overriding(runtimeID, field, level, with: native)
        Task { await model.setAutoSettings(s) }
    }
}
