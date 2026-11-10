import AgentsKitCore
import SwiftUI

/// A connector's tools, each with Allow, Ask or Off, and one switch for every tool that
/// writes (#4099). Written to your layer for a connector of yours and to the folder's
/// `.agents/policy.json` for one of the folder's; a layer above can only make them tighter,
/// so a looser choice than its cap is kept and the cap's line says why it does not apply.
struct ConnectorToolsList: View {
    @Environment(AppModel.self) private var model
    let name: String
    var place: AgentsPlace

    @State private var answer: DaemonAPI.MCPToolsAnswer?
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let answer {
                writesSwitch(answer)
                if let problem = answer.problem {
                    Text(problem).appText(.supporting).foregroundStyle(.secondary)
                } else if answer.tools.isEmpty {
                    Text(ConnectorToolWords.none).appText(.supporting).foregroundStyle(.secondary)
                }
                ForEach(answer.tools) { row in
                    toolRow(row, writes: answer.writes)
                }
            } else {
                ProgressView().controlSize(.small)
            }
            if let failure {
                Text(failure).appText(.fine).foregroundStyle(SharedInk.attention)
            }
        }
        .padding(.top, 4)
        .task(id: name) { answer = await model.mcpTools(name, at: place.destination) }
    }

    private func writesSwitch(_ answer: DaemonAPI.MCPToolsAnswer) -> some View {
        HStack(spacing: 8) {
            Text(ConnectorToolWords.writesTitle).appText(.supporting).fontWeight(.semibold)
            Spacer(minLength: 8)
            if let line = answer.writesCapLine {
                Text(line).appText(.fine).foregroundStyle(.secondary)
            }
            Picker(ConnectorToolWords.writesTitle, selection: Binding(
                get: { answer.writes },
                set: { level in set(tool: nil, to: level) })) {
                Text(ConnectorToolWords.eachTool).tag(DaemonAPI.ConnectorToolLevel?.none)
                ForEach(DaemonAPI.ConnectorToolLevel.allCases, id: \.self) { level in
                    Text(ConnectorToolWords.title(level)).tag(Optional(level))
                }
            }
            .labelsHidden()
            .fixedSize()
        }
    }

    private func toolRow(_ row: DaemonAPI.MCPToolRow, writes: DaemonAPI.ConnectorToolLevel?) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(row.name).appText(.supporting).lineLimit(1).layoutPriority(1)
                    if row.writes { SharedChip(text: ConnectorToolWords.writesChip, tone: .source) }
                }
                if let line = detail(row) {
                    Text(line).appText(.fine).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Picker(row.name, selection: Binding(
                get: { row.own },
                set: { level in set(tool: row.name, to: level) })) {
                Text(ConnectorToolWords.byDefault(ConnectorToolWords.defaultLevel(row, writes: writes)))
                    .tag(DaemonAPI.ConnectorToolLevel?.none)
                ForEach(DaemonAPI.ConnectorToolLevel.allCases, id: \.self) { level in
                    Text(ConnectorToolWords.title(level)).tag(Optional(level))
                }
            }
            .labelsHidden()
            .fixedSize()
            .help(ConnectorToolWords.help(row.level))
        }
        .accessibilityElement(children: .contain)
    }

    /// The tool's title, and the cap's line when a layer above holds it tighter than its own.
    private func detail(_ row: DaemonAPI.MCPToolRow) -> String? {
        let capped = row.capLine.flatMap { line in row.own.map { $0.order < (row.cap?.order ?? 0) } == true ? line : nil }
        let parts = [row.title, capped].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func set(tool: String?, to level: DaemonAPI.ConnectorToolLevel?) {
        Task {
            switch await model.setMCPToolLevel(name, tool: tool, to: level, at: place.destination) {
            case .success(let fresh):
                answer = fresh
                failure = nil
            case .failure(let error):
                failure = MCPCatalogWords.sentence(error)
            }
        }
    }
}
