import AgentsKitCore
import SwiftUI

/// What a session is linked to (#2940), as the web page's Lineage tab: the issues, pull
/// requests, helpers and workflow runs within two links of it, each with its links and, for an
/// issue or a PR, what was banked on it. The links are the session's, not one turn's, so it is a
/// pane of the column and not a part of the turn detail. A graph of boxes and lines (#3019).
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
    /// The graph laid out, each time `graph` or `costs` is set, not in `body` (#3112).
    @State private var layout: LineageLayout.Graph?
    @State private var failure: String?
    /// The daemon is still resolving titles and the graph is walked again each second.
    @State private var reading = false
    @State private var asked = 0

    private var me: LineageList.Node { LineageList.node(ofSession: agent.id) }

    private func title(_ node: LineageList.Node) -> String? {
        guard node.kind == "session", let id = UUID(uuidString: String(node.ref.dropFirst("session:".count))) else { return nil }
        return model.work.agent(id)?.title
    }

    var body: some View {
        Group {
            if let failure {
                message(failure)
            } else if graph == nil {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let graph, !graph.nodes.contains(where: { $0 != me }) {
                message(LineageList.none)
            } else if let layout {
                LineageGraphView(graph: layout, open: action(for:), verb: verb(for:))
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        footer.padding(.horizontal, 12).padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack {
                Spacer()
                if popped == nil {
                    Button("Explore") { model.showLineage(from: LineagePlace(host: agent.host, node: me)) }
                        .buttonStyle(.link)
                        .help("Open it on the Lineage page, where a click on a box starts from it")
                }
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

    private var footer: some View {
        VStack(alignment: .leading, spacing: 2) {
            if reading {
                Text(LineageList.readingTitles)
                    .appText(.fine).foregroundStyle(.secondary)
            }
            if graph?.limited == true {
                Text("The walk stopped at its limit: there are more links.")
                    .appText(.fine).foregroundStyle(.secondary)
            }
            Text(LineageList.note)
                .appText(.fine).foregroundStyle(.tertiary)
        }
    }

    private struct Ask: Equatable {
        var visible: Bool
        var asked: Int
    }

    private func load() async {
        reading = false
        do {
            let walked = try await model.lineageWalk(of: agent.id)
            failure = nil
            graph = walked
            lay()
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
            lay()
            // The daemon resolves issues' and PRs' titles in the background (#3102): walk
            // again while it says some are still to come.
            // One failed walk keeps the graph that is shown and stops asking (#3154).
            var latest = walked
            reading = latest.resolving == true
            for _ in 0 ..< LineageList.resolvingAsks where latest.resolving == true {
                do {
                    try await Task.sleep(for: .seconds(1))
                    latest = try await model.lineageWalk(of: agent.id)
                } catch {
                    break
                }
                guard !Task.isCancelled else { return }
                graph = latest
                lay()
            }
            guard !Task.isCancelled else { return }
            reading = false
        } catch {
            guard !Task.isCancelled else { return }
            failure = "The links could not be read: \(error.localizedDescription)"
        }
    }

    private func lay() {
        layout = graph.map { LineageLayout.graph(of: me, graph: $0, costs: costs, title: title) }
    }

    /// An issue, a PR, a milestone or a release opens its Work page (#3088), else on GitHub; a
    /// session in this window goes to its chat.
    private func action(for row: LineageList.Row) -> (() -> Void)? {
        if row.node == me { return nil }
        if popped == nil, let kind = WorkList.kind(of: row.node) {
            return { model.showWork(WorkPlace(kind: kind, ref: row.node.ref)) }
        }
        if let url = row.url { return { openURL(url) } }
        if popped == nil, let id = row.session, model.work.agent(id) != nil { return { model.selection = id } }
        return nil
    }

    private func verb(for row: LineageList.Row) -> String {
        if popped == nil, WorkList.kind(of: row.node) != nil { return "Open its page" }
        return row.url != nil ? "Open it on GitHub" : "Show this session"
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
