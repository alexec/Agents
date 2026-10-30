import AgentsKitCore
import SwiftUI

/// What a session is linked to (#2940), as the web page's Lineage tab: the issues, pull
/// requests, helpers and workflow runs within two links of it, each with its links and, for an
/// issue or a PR, what was banked on it. A list, not a graph drawing: the links are the
/// session's, not one turn's, so it is a pane of the column and not a part of the turn detail.
struct LineagePane: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    /// In a folder's window there is only its own session to go to (#1089).
    @Environment(\.poppedChat) private var popped
    let agent: Agent
    /// Read again each time the pane is shown: links come as the session works.
    let isVisible: Bool

    @State private var graph: DaemonAPI.LineageGraph?
    @State private var costs: [DaemonAPI.LineageNode: DaemonAPI.LineageCostRollup] = [:]
    @State private var failure: String?
    @State private var asked = 0

    private var groups: [LineageList.Group] {
        guard let graph else { return [] }
        return LineageList.groups(of: LineageList.node(ofSession: agent.id), graph: graph, costs: costs) { node in
            guard node.kind == "session", let id = UUID(uuidString: String(node.ref.dropFirst("session:".count))) else { return nil }
            return model.work.agent(id)?.title
        }
    }

    var body: some View {
        Group {
            if let failure {
                message(failure)
            } else if graph == nil {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if groups.isEmpty {
                message(LineageList.none)
            } else {
                List {
                    ForEach(groups) { group in
                        Section(group.title) {
                            ForEach(group.rows) { row in
                                LineageRowView(row: row, open: action(for: row))
                            }
                        }
                    }
                    Section {
                        if graph?.limited == true {
                            Text("The walk stopped at its limit: there are more links.")
                                .appText(.fine).foregroundStyle(.secondary)
                        }
                        Text(LineageList.note)
                            .appText(.fine).foregroundStyle(.tertiary)
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack {
                Spacer()
                Button("Refresh") { asked += 1 }
                    .buttonStyle(.link)
                    .help("Read the links and the costs again")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
        }
        .task(id: Ask(visible: isVisible, asked: asked)) {
            guard isVisible else { return }
            await load()
        }
    }

    private struct Ask: Equatable {
        var visible: Bool
        var asked: Int
    }

    private func load() async {
        do {
            let walked = try await model.lineageWalk(of: agent.id)
            failure = nil
            graph = walked
            var found: [DaemonAPI.LineageNode: DaemonAPI.LineageCostRollup] = [:]
            await withTaskGroup(of: DaemonAPI.LineageCostRollup?.self) { group in
                for node in walked.nodes where LineageList.costed(node) {
                    group.addTask { await model.lineageCost(node, of: agent.id) }
                }
                for await rollup in group {
                    if let rollup { found[rollup.node] = rollup }
                }
            }
            guard !Task.isCancelled else { return }
            costs = found
        } catch {
            guard !Task.isCancelled else { return }
            failure = "The links could not be read: \(error.localizedDescription)"
        }
    }

    /// A GitHub issue or PR opens in the browser; a session in this window goes to its chat.
    private func action(for row: LineageList.Row) -> (() -> Void)? {
        if let url = row.url { return { openURL(url) } }
        if popped == nil, let id = row.session, model.work.agent(id) != nil { return { model.selection = id } }
        return nil
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .appText(.supporting)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct LineageRowView: View {
    let row: LineageList.Row
    let open: (() -> Void)?

    var body: some View {
        if let open {
            Button(action: open) { content }
                .buttonStyle(.plain)
                .help(row.url != nil ? "Open it on GitHub" : "Show this session")
        } else {
            content
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(row.name)
                .appText(.reading).fontWeight(.medium)
                .foregroundStyle(open == nil ? .primary : Paper.accent)
                .lineLimit(1)
                .truncationMode(.middle)
            if let cost = row.cost {
                Text(cost)
                    .appText(.supporting)
                    .monospacedDigit()
            }
            ForEach(row.links, id: \.self) { line in
                Text(line)
                    .appText(.fine)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}
