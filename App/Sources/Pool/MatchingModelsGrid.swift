import AgentsKitCore
#if !AGENTS_STORE
import AgentsKit
#endif
import SwiftUI

/// Matching models (052, US6; wireframes §1): one column per runtime in the pool, one
/// row per level the person names. A chat switching keeps its level, so the new runtime
/// gets that level's model.
///
/// Each cell is a menu of the models its runtime offers (`pool/models`). Choosing a model
/// already in another level moves it there, since a model sits in one level for its
/// runtime (FR-032). A cell whose model is no longer offered is struck through, and a
/// switch treats it as empty. Two entries for one runtime share its column.
struct MatchingModelsGrid: View {
    @Environment(AppModel.self) private var model
    let status: PoolStatus
    @State private var offered: [String: [ConfigOption]] = [:]
    @State private var renaming: Level?
    @State private var newName = ""
    @State private var refusal: String?

    /// The runtimes in pool order, each once.
    private var columns: [String] {
        var seen = Set<String>()
        return status.rows.map(\.entry.runtimeID).filter { seen.insert($0).inserted }
    }

    private var pool: PoolSettings { status.settings }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("MATCHING MODELS")
                    .appText(.fine).fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("A chat switching keeps its level: the new runtime gets that level's model.")
                    .appText(.fine).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 10) {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                    GridRow {
                        Text("Level")
                        ForEach(columns, id: \.self) { Text(PoolWords.runtimeName($0)) }
                    }
                    .appText(.fine).fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    Divider().gridCellUnsizedAxes(.horizontal)
                    if pool.levels.isEmpty {
                        GridRow {
                            Text("No levels yet. Add one, or let Continue with… remember the models you pick.")
                                .appText(.supporting).foregroundStyle(.secondary)
                                .gridCellColumns(columns.count + 1)
                        }
                    }
                    ForEach(Array(pool.levels.enumerated()), id: \.element.id) { index, level in
                        GridRow {
                            levelName(level, at: index)
                            ForEach(columns, id: \.self) { runtimeID in
                                cellMenu(level: level, runtimeID: runtimeID)
                            }
                        }
                    }
                }
                HStack {
                    Button("Add a level") { save(pool.addingLevel().pool) }
                        .buttonStyle(.link)
                    if let refusal {
                        Text(refusal).appText(.fine).foregroundStyle(StateTint.failure.style(or: .primary))
                    }
                }
                .appText(.fine)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .paperRaised(in: RoundedRectangle(cornerRadius: 10))
        }
        .task(id: columns) { offered = await model.poolModels(columns) }
        .alert("Rename the level", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") {
                if let level = renaming, let index = pool.levels.firstIndex(where: { $0.id == level.id }) {
                    var next = pool
                    next.levels[index].name = newName
                    save(next)
                }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }

    // MARK: Parts

    /// A level's name, with renaming, moving and removing on its menu.
    private func levelName(_ level: Level, at index: Int) -> some View {
        Menu(level.name) {
            Button("Rename…") { newName = level.name; renaming = level }
            Button("Move up") { save(moving(from: index, by: -1)) }.disabled(index == 0)
            Button("Move down") { save(moving(from: index, by: 1)) }.disabled(index == pool.levels.count - 1)
            Divider()
            Button("Remove this level") {
                var next = pool
                next.levels.removeAll { $0.id == level.id }
                save(next)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .appText(.reading).fontWeight(.semibold)
    }

    /// One cell: the level's model for this runtime, as a menu of what it offers.
    private func cellMenu(level: Level, runtimeID: String) -> some View {
        let cell = level.cells[runtimeID]
        let options = offered[runtimeID] ?? []
        let modelOption = SettingsCarry.model(in: options)
        let isGone = cell.map { PoolSettings.isGone($0, offered: options) } ?? false
        let label = cell.map { cell in
            let name = modelOption?.options?.first { $0.value == cell.model }?.name ?? cell.model.stringValue ?? "\(cell.model)"
            return cell.effort?.stringValue.map { "\(name) · \($0)" } ?? name
        }
        return Menu {
            if let choices = modelOption?.options, !choices.isEmpty {
                ForEach(choices) { choice in
                    Button(choice.name) {
                        save(pool.placing(Cell(model: choice.value, effort: cell?.effort, effortOptionID: cell?.effortOptionID),
                                          for: runtimeID, in: level.id))
                    }
                }
            } else {
                Text("\(PoolWords.runtimeName(runtimeID)) has not said what it offers yet.")
            }
            if cell != nil {
                Divider()
                Button("Clear") { save(pool.placing(nil, for: runtimeID, in: level.id)) }
            }
        } label: {
            Text(label ?? "Choose…")
                .strikethrough(isGone)
                .foregroundStyle(label == nil || isGone ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .appText(.supporting)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(minWidth: 130, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 6)
            .strokeBorder(Paper.rule, style: StrokeStyle(lineWidth: 1, dash: label == nil ? [3, 3] : [])))
        .help(isGone ? "\(PoolWords.runtimeName(runtimeID)) no longer offers this model, so a switch treats it as empty" : "")
    }

    // MARK: Changing

    private func moving(from index: Int, by offset: Int) -> PoolSettings {
        var next = pool
        let level = next.levels.remove(at: index)
        next.levels.insert(level, at: index + offset)
        return next
    }

    private func save(_ next: PoolSettings) {
        Task { refusal = await model.setPool(next) }
    }
}
