import AgentsKit
import SwiftUI

/// Matching models (052, US6; wireframes §1): one column per runtime in the pool, one
/// row per level the person names. A chat switching keeps its level, so the new runtime
/// gets that level's model.
///
/// Read-only until US6 makes the cells menus. Two entries for one runtime share its
/// column, because the models are the same.
struct MatchingModelsGrid: View {
    let status: PoolStatus

    /// The runtimes in pool order, each once.
    private var columns: [String] {
        var seen = Set<String>()
        return status.rows.map(\.entry.runtimeID).filter { seen.insert($0).inserted }
    }

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
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("Level")
                    ForEach(columns, id: \.self) { Text(PoolWords.runtimeName($0)) }
                }
                .appText(.fine).fontWeight(.semibold)
                .foregroundStyle(.secondary)
                Divider().gridCellUnsizedAxes(.horizontal)
                if status.settings.levels.isEmpty {
                    GridRow {
                        Text("No levels yet. Continue with… offers to remember the models you pick.")
                            .appText(.supporting).foregroundStyle(.secondary)
                            .gridCellColumns(columns.count + 1)
                    }
                }
                ForEach(status.settings.levels) { level in
                    GridRow {
                        Text(level.name).appText(.reading).fontWeight(.semibold)
                        ForEach(columns, id: \.self) { runtimeID in
                            ModelCell(cell: level.cells[runtimeID])
                        }
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .paperRaised(in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

/// One cell: a model, and its effort where the runtime has one, or an empty place.
private struct ModelCell: View {
    let cell: Cell?

    private var label: String? {
        guard let cell else { return nil }
        let model = cell.model.stringValue ?? "\(cell.model)"
        guard let effort = cell.effort?.stringValue else { return model }
        return "\(model) · \(effort)"
    }

    var body: some View {
        Text(label ?? "Choose…")
            .appText(.supporting)
            .foregroundStyle(label == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(minWidth: 130, alignment: .leading)
            .overlay(RoundedRectangle(cornerRadius: 6)
                .strokeBorder(.quaternary, style: StrokeStyle(lineWidth: 1, dash: label == nil ? [3, 3] : [])))
    }
}
