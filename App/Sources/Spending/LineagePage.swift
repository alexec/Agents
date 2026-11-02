import AgentsKitCore
import SwiftUI

/// A start of the Lineage page (#3087): a node, and the machine whose links are walked from it.
struct LineagePlace: Hashable, Sendable {
    var host: MachineRef
    var node: DaemonAPI.LineageNode
}

/// The Lineage page (#3087), as the web page's Reports ▸ Lineage: the work's cost, time and links
/// from any start (a session, an issue, a pull request, a milestone or a release), not only from
/// the session open. A click on a box starts the walk from it; Back and Forward go along the
/// starts, as a browser's. The graph is the session pane's (#3019).
struct LineagePage: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL

    @State private var typed = ""
    @State private var typedWrong = false
    @State private var graph: DaemonAPI.LineageGraph?
    @State private var costs: [DaemonAPI.LineageNode: DaemonAPI.LineageCostRollup] = [:]
    /// The graph laid out, each time `graph` or `costs` is set, not in `body` (#3112).
    @State private var layout: LineageLayout.Graph?
    @State private var failure: String?
    /// The daemon is still resolving titles and the graph is walked again each second.
    @State private var reading = false
    @State private var asked = 0
    /// The machine chosen in the Machine menu (#3157), for a typed start.
    @State private var chosen: MachineRef?

    private var place: LineagePlace? { model.lineageHistory.current }

    /// The machine a typed start is walked on (#3157): the one chosen, else the selected folder's
    /// when it keeps links, else the first that does.
    private var machine: MachineRef {
        let machines = model.lineageMachines
        if let chosen, machines.contains(where: { $0.id == chosen }) { return chosen }
        if machines.isEmpty || machines.contains(where: { $0.id == model.lineageHost }) { return model.lineageHost }
        return machines[0].id
    }

    /// The machine's name, when more than one machine keeps links and a name is worth saying.
    private func machineName(_ host: MachineRef) -> String? {
        let machines = model.lineageMachines
        guard machines.count > 1 else { return nil }
        return machines.first { $0.id == host }?.name
    }

    /// The folder's newest sessions, to start from one.
    private var sessions: [Agent] {
        Array(model.work.agents.filter { $0.archivedAt == nil }.sorted { $0.lastActivityAt > $1.lastActivityAt }.prefix(15))
    }

    var body: some View {
        VStack(spacing: 0) {
            bar.padding(.horizontal, 16).padding(.vertical, 8)
            Divider()
            content
        }
        .task(id: Ask(place: place, asked: asked)) { await load() }
        .onAppear {
            // With nothing walked yet, the session open is where it starts.
            if place == nil, let id = model.selection, let agent = model.work.agent(id) {
                model.lineageHistory.go(LineagePlace(host: agent.host, node: LineageList.node(ofSession: id)))
            }
        }
    }

    private var bar: some View {
        HStack(spacing: 8) {
            Button { model.lineageHistory.back() } label: { Image(systemName: "chevron.left") }
                .disabled(!model.lineageHistory.canGoBack)
                .help("Back: the start before this one")
            Button { model.lineageHistory.forward() } label: { Image(systemName: "chevron.right") }
                .disabled(!model.lineageHistory.canGoForward)
                .help("Forward")
            TextField("An issue’s, a pull request’s, a milestone’s or a release’s address, or owner/repo#12",
                      text: $typed)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Start from")
                .onSubmit(startTyped)
                .onChange(of: typed) { typedWrong = false }
            if model.lineageMachines.count > 1 {
                Menu(machineName(machine) ?? "Machine") {
                    ForEach(model.lineageMachines, id: \.id) { choice in
                        Button(choice.name) { choose(choice.id) }
                    }
                }
                .fixedSize()
                .accessibilityLabel("Machine")
                .help("The machine whose links are walked")
            }
            Menu("Session") {
                ForEach(sessions) { agent in
                    Button(agent.title ?? "Untitled") {
                        model.lineageHistory.go(LineagePlace(host: agent.host, node: LineageList.node(ofSession: agent.id)))
                    }
                }
            }
            .fixedSize()
            .disabled(sessions.isEmpty)
            .help("Start from one of this folder’s sessions")
            Button("Refresh") { asked += 1 }
                .buttonStyle(.link)
                .disabled(place == nil)
                .help("Read the links and the costs again")
        }
    }

    private func startTyped() {
        guard let node = LineageList.node(typed: typed) else { typedWrong = true; return }
        let host = node.kind == "session" ? sessionHost(node) ?? machine : machine
        let pr = LineageList.pullRequest(typed: typed)
        typed = ""
        guard let pr else { model.lineageHistory.go(LineagePlace(host: host, node: node)); return }
        // "owner/repo#12" is an issue or a pull request (#3148): the pull request when only it has links.
        Task {
            var start = node
            if await !linked(node, on: host), await linked(pr, on: host) { start = pr }
            model.lineageHistory.go(LineagePlace(host: host, node: start))
        }
    }

    /// A machine chosen: a start that is not a session is walked again on it (#3157).
    private func choose(_ host: MachineRef) {
        chosen = host
        if let place, place.node.kind != "session", place.host != host {
            model.lineageHistory.go(LineagePlace(host: host, node: place.node))
        }
    }

    private func linked(_ node: DaemonAPI.LineageNode, on host: MachineRef) async -> Bool {
        (try? await model.lineageWalk(node, on: host).links.isEmpty == false) ?? false
    }

    @ViewBuilder
    private var content: some View {
        if typedWrong {
            message("That is not an address Lineage knows. Type a GitHub issue’s, pull request’s, milestone’s or release’s address, owner/repo#12, or a session’s id.")
        } else if let place {
            if !model.host(place.host, has: Capability.lineage1) {
                HostNeedsUpdateView()
            } else if let failure {
                message(failure)
            } else if let graph, let layout {
                VStack(spacing: 0) {
                    heading(LineageList.start(place.node, graph: graph, costs: costs, title: title), on: place.host)
                    if layout.nodes.isEmpty {
                        message(LineageList.pageNone)
                    } else {
                        LineageGraphView(graph: layout, open: { row in start(row) }, verb: { _ in "Start from it" })
                            .safeAreaInset(edge: .bottom, spacing: 0) { footer }
                    }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            message("Start from a session, or type an issue’s, a pull request’s, a milestone’s or a release’s address. Then click a box to start from it.")
        }
    }

    /// The start's name and what it is, the machine it is walked on (#3157), and where to open it:
    /// its Work page (#3088), on GitHub, or its chat.
    private func heading(_ row: LineageList.Row, on host: MachineRef) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(row.node.kind == "session" ? title(row.node) ?? "A session" : row.name)
                .appText(.reading).fontWeight(.semibold)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(row.ref ?? row.name)
            Text(([LineageLayout.kindWord(row.node.kind)] + [row.cost, row.resolved, machineName(host).map { "on \($0)" }].compactMap { $0 })
                .joined(separator: " · "))
                .appText(.supporting)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
            Spacer()
            if let kind = WorkList.kind(of: row.node) {
                Button("Open its page") { model.showWork(WorkPlace(kind: kind, ref: row.node.ref)) }
                    .buttonStyle(.link)
                    .help("Its Work page: what its forge says, its links and its cost")
            } else if let url = row.url {
                Button("Open on GitHub") { openURL(url) }.buttonStyle(.link)
            } else if let id = row.session, model.work.agent(id) != nil {
                Button("Show the Chat") { model.openAgent(id) }.buttonStyle(.link)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
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
            Text(LineageList.pageNote)
                .appText(.fine).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A click on a box: the walk starts from it, on its session's machine for a session.
    private func start(_ row: LineageList.Row) -> (() -> Void)? {
        guard let place, row.node != place.node else { return nil }
        let host = sessionHost(row.node) ?? place.host
        return { model.lineageHistory.go(LineagePlace(host: host, node: row.node)) }
    }

    private func sessionHost(_ node: LineageList.Node) -> MachineRef? {
        guard node.kind == "session", let id = UUID(uuidString: String(node.ref.dropFirst("session:".count))) else { return nil }
        return model.work.agent(id)?.host
    }

    private func title(_ node: LineageList.Node) -> String? {
        guard node.kind == "session", let id = UUID(uuidString: String(node.ref.dropFirst("session:".count))) else { return nil }
        return model.work.agent(id)?.title
    }

    private struct Ask: Equatable {
        var place: LineagePlace?
        var asked: Int
    }

    private func load() async {
        reading = false
        graph = nil
        layout = nil
        failure = nil
        costs = [:]
        guard let place, model.host(place.host, has: Capability.lineage1) else { return }
        do {
            let walked = try await model.lineageWalk(place.node, on: place.host)
            guard !Task.isCancelled else { return }
            graph = walked
            lay(place)
            var found: [DaemonAPI.LineageNode: DaemonAPI.LineageCostRollup] = [:]
            await withTaskGroup(of: DaemonAPI.LineageCostRollup?.self) { group in
                for node in walked.nodes where LineageList.costed(node) {
                    group.addTask { await model.lineageCost(node, on: place.host) }
                }
                for await rollup in group {
                    if let rollup { found[rollup.node] = rollup }
                }
            }
            guard !Task.isCancelled else { return }
            costs = found
            lay(place)
            // The daemon resolves issues' and PRs' titles in the background (#3102): walk
            // again while it says some are still to come.
            // One failed walk keeps the graph that is shown and stops asking (#3154).
            var latest = walked
            reading = latest.resolving == true
            for _ in 0 ..< LineageList.resolvingAsks where latest.resolving == true {
                do {
                    try await Task.sleep(for: .seconds(1))
                    latest = try await model.lineageWalk(place.node, on: place.host)
                } catch {
                    break
                }
                guard !Task.isCancelled else { return }
                graph = latest
                lay(place)
            }
            guard !Task.isCancelled else { return }
            reading = false
        } catch {
            guard !Task.isCancelled else { return }
            failure = "The links could not be read: \(error.localizedDescription)"
        }
    }

    private func lay(_ place: LineagePlace) {
        layout = graph.map { LineageLayout.graph(of: place.node, graph: $0, costs: costs, title: title) }
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
