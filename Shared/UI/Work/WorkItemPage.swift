import AgentsKitCore
import SwiftUI

/// The page of one issue, pull request, milestone or release (#3119), as the web page's
/// `#/work/<kind>/<ref>`: the item from its forge (`forge/issue`, `forge/pull`) on the first
/// machine that reads it, and what lineage knows on a machine that keeps links: its cost, its
/// links by relation and the graph centred here (#3087). It opens for any item, also one no agent
/// touched. A link opens that node's page; a session's opens its chat. An issue's and a pull
/// request's actions (#3130, `WorkItemActions`) go to the machine that read it.
struct WorkItemPage: View {
    let model: any WorkModel
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var compact: Bool { sizeClass == .compact }
    #else
    private let compact = false
    #endif
    @Environment(\.openURL) private var openURL
    let place: WorkPlace

    @State private var detail: (host: MachineRef, got: DaemonAPI.ForgeItemDetail)?
    @State private var forgeProblem: String?
    @State private var olderLoading = false
    @State private var graph: DaemonAPI.LineageGraph?
    @State private var costs: [DaemonAPI.LineageNode: DaemonAPI.LineageCostRollup] = [:]
    @State private var layout: LineageLayout.Graph?
    @State private var linksFailed = false
    @State private var reading = false
    @State private var asked = 0

    private var node: DaemonAPI.LineageNode { place.node ?? .init(kind: place.kind.rawValue, ref: "") }

    /// Lineage from the machine that read the forge, else This Mac, else the first that keeps links.
    private var lineageHost: MachineRef? {
        let machines = model.lineageMachines
        if let host = detail?.host, machines.contains(where: { $0.id == host }) { return host }
        return machines.first?.id
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if let detail, model.forgeWrites(on: detail.host) {
                    WorkItemActions(model: model, host: detail.host, detail: detail.got, wrote: { Task { await reread() } })
                }
                if let forgeProblem {
                    Label(forgeProblem, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                } else if place.kind.fromForge, detail == nil {
                    ProgressView()
                }
                #if os(macOS)
                // An epic's plan (#3268): Mac + web, so not on the Remote (#2796).
                if let detail, WorkPlan.hasPlan(detail.got.item) {
                    WorkPlanSection(model: model, host: detail.host, lineageHost: lineageHost, detail: detail.got, asked: asked,
                                    writes: model.forgeWrites(on: detail.host), wrote: { Task { await reread() } })
                }
                #endif
                if let detail { bodyAndComments(detail.got, on: detail.host) }
                #if os(macOS)
                // The docs it names and those like it (#3322): Mac + web, so not on the Remote (#2796).
                if let detail, detail.got.item.node.kind == "issue" || detail.got.item.node.kind == "pr" {
                    WorkDocsSection(item: detail.got.item, text: detail.got.body, asked: asked)
                }
                #endif
                lineage
            }
            .padding(compact ? 16 : 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        #if os(iOS)
        .refreshable { asked += 1 }
        #endif
        .workTask(id: asked) { await loadForge() }
        .workTask(id: LineageAsk(host: lineageHost, asked: asked)) { await loadLineage() }
    }

    private struct LineageAsk: Equatable {
        var host: MachineRef?
        var asked: Int
    }

    // MARK: Header

    /// The project the item was read for (#3283), when the person has more than one: with one, the
    /// page says nothing new.
    private var projectWords: String? {
        let projects = model.workProjects
        guard projects.count > 1, let detail else { return nil }
        return WorkList.project(ofFolder: detail.got.item.folder, on: detail.host, in: projects).map { WorkList.projectWords($0.name) }
    }

    private var header: some View {
        let item = detail?.got.item
        let resolved = graph?.resolved?[node.ref]
        let labels = item?.labels ?? (resolved?.labels ?? []).map { DaemonAPI.ForgeLabel(name: $0) }
        let url = item?.url.flatMap(URL.init(string:)) ?? WorkList.url(node)
        let title = item?.title ?? resolved?.title ?? ReportValueWords.name(node)
        return VStack(alignment: .leading, spacing: 6) {
            if compact {
                // A phone has no room beside the title: All and Refresh go above it.
                HStack(spacing: 16) { pageLinks }
                titleLine(title)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    titleLine(title)
                    Spacer()
                    pageLinks
                }
            }
            WrappingHStack(spacing: 6) {
                WorkStatePill(state: item?.state ?? resolved?.state ?? "", draft: item?.draft ?? false, status: item?.status)
                ForEach(labels, id: \.name) { WorkLabelChip(label: $0) }
            }
            // On a phone the ref takes the line, and "Open on …" goes under it.
            (compact ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4)) : AnyLayout(HStackLayout(spacing: 6))) {
                Text(([node.ref] + [item.map(WorkList.peopleWords), projectWords].compactMap { $0 }.filter { !$0.isEmpty })
                    .joined(separator: " · "))
                    .appText(.supporting).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if let url {
                    Button(WorkList.openOnWords(node.ref)) { openURL(url) }.linkStyle()
                }
            }
            if let item, item.node.kind == "pr" {
                let words = [WorkList.checksWords(detail?.got.checks, summary: item.checks), WorkList.reviewWords(item.review)]
                    .compactMap { $0 }
                if !words.isEmpty {
                    Text(words.joined(separator: " · ")).appText(.supporting)
                }
            }
        }
    }

    @ViewBuilder
    private func titleLine(_ title: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text.forgeTitle(title)
                .appText(.title).fontWeight(.semibold)
                .textSelection(.enabled)
            if !WorkList.titleSaysRef(title, node.ref) {
                Text(WorkList.shortRef(node.ref)).appText(.title).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var pageLinks: some View {
        Button("All \(place.kind.title.lowercased())") { model.showWork(WorkPlace(kind: place.kind)) }
            .linkStyle()
        Button("Refresh") { asked += 1 }.linkStyle()
        stepper
    }

    /// Previous and Next through the list the page was opened from (#3257), and where it stands
    /// in it. None on a page opened from a link or an address.
    @ViewBuilder
    private var stepper: some View {
        if let n = model.workNeighbours {
            let list = model.workLists[place.kind]
            HStack(spacing: 8) {
                Button { Task { await model.stepWork(forward: false) } } label: { stepLabel("chevron.up") }
                    .disabled(n.previous == nil)
                    .help("Previous item (⌥⌘↑)")
                    .accessibilityLabel("Previous")
                Text(WorkList.positionWords(n, more: list.hasMore))
                    .appText(.supporting).foregroundStyle(.secondary).monospacedDigit()
                    .lineLimit(1).fixedSize()
                Button { Task { await model.stepWork(forward: true) } } label: {
                    if list.loadingMore { ProgressView().controlSize(.small) } else { stepLabel("chevron.down") }
                }
                .disabled(!model.workHasNext || list.loadingMore)
                .help("Next item (⌥⌘↓)")
                .accessibilityLabel("Next")
            }
            .buttonStyle(.borderless)
        }
    }

    /// An arrow with a target a finger or a pointer finds: 44 points on the Remote, 24 on the Mac.
    private func stepLabel(_ symbol: String) -> some View {
        #if os(iOS)
        let side: CGFloat = 44
        #else
        let side: CGFloat = 24
        #endif
        return Image(systemName: symbol).frame(width: side, height: side).contentShape(Rectangle())
    }

    // MARK: Body and comments

    @ViewBuilder
    private func bodyAndComments(_ got: DaemonAPI.ForgeItemDetail, on host: MachineRef) -> some View {
        Divider()
        if got.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text("No description.").foregroundStyle(.secondary)
        } else {
            MarkdownText(markdown: ForgeMarkdown.markdown(got.body))
        }
        if !got.comments.isEmpty || got.cursor != nil {
            Text("Comments").appText(.reading).fontWeight(.semibold).padding(.top, 8)
            if got.cursor != nil {
                Button(olderLoading ? "Loading…" : "Older comments") { Task { await readOlder() } }
                    .linkStyle()
                    .disabled(olderLoading)
            }
            ForEach(Array(got.comments.enumerated()), id: \.offset) { _, c in
                VStack(alignment: .leading, spacing: 4) {
                    Divider()
                    Text("\(c.author)\(c.bot == true ? " (bot)" : "") · \(c.at.formatted(.relative(presentation: .named)))")
                        .appText(.fine).foregroundStyle(.secondary)
                    MarkdownText(markdown: ForgeMarkdown.markdown(c.body))
                }
            }
        }
        if model.forgeWrites(on: host) {
            WorkCommentBox(model: model, host: host, node: got.item.node, wrote: { Task { await reread() } })
                .padding(.top, 8)
        }
    }

    // MARK: Lineage

    @ViewBuilder
    private var lineage: some View {
        Divider()
        Text("Lineage").appText(.reading).fontWeight(.semibold)
        if lineageHost == nil {
            Text("No machine keeps links yet. Update Agents on a machine to see them.").foregroundStyle(.secondary)
        } else if graph == nil, !linksFailed {
            ProgressView()
        } else {
            let groups = WorkList.linkGroups(node, graph?.links ?? [])
            if groups.isEmpty {
                Text(WorkList.noAgentOnIt).foregroundStyle(.secondary)
            } else {
                if let words = costs[node].flatMap(WorkList.pageCostWords) {
                    Text("\(Text("Cost").foregroundStyle(.secondary))  \(words)").monospacedDigit()
                }
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 4) {
                    ForEach(groups, id: \.title) { group in
                        ForEach(Array(group.rows.enumerated()), id: \.offset) { i, row in
                            GridRow {
                                Text(i == 0 ? group.title : "").foregroundStyle(.secondary)
                                linkRow(row.node, ended: row.ended)
                            }
                        }
                    }
                }
                if let layout, !layout.nodes.isEmpty {
                    LineageGraphView(graph: layout, open: { open($0.node) },
                                     verb: { $0.session != nil ? "Show the chat" : "Open its page" })
                        .frame(height: 360)
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
                }
                if reading {
                    Text(LineageList.readingTitles).appText(.fine).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func linkRow(_ other: DaemonAPI.LineageNode, ended: Bool) -> some View {
        let words = name(other) + (other.kind == "session" ? "" : " (\(LineageLayout.kindWord(other.kind).lowercased()))")
            + (ended ? " · ended" : "")
        if let go = open(other) {
            Button(words + (other.kind == "session" ? " ▸ chat" : " ▸"), action: go).linkStyle()
        } else {
            Text(words)
        }
    }

    private func sessionID(_ n: DaemonAPI.LineageNode) -> UUID? {
        n.kind == "session" ? UUID(uuidString: String(n.ref.dropFirst("session:".count))) : nil
    }

    private func name(_ n: DaemonAPI.LineageNode) -> String {
        if let id = sessionID(n) { return model.workSessionTitle(id) ?? "A session" }
        return graph?.resolved?[n.ref]?.title ?? ReportValueWords.name(n)
    }

    /// A session opens its chat; an issue, a PR, a milestone or a release its page; the page itself nothing.
    private func open(_ n: DaemonAPI.LineageNode) -> (() -> Void)? {
        guard n != node else { return nil }
        if let id = sessionID(n) {
            return model.workSessionTitle(id) == nil ? nil : { model.openWorkSession(id) }
        }
        guard let kind = WorkList.kind(of: n) else { return nil }
        return { model.showWork(WorkPlace(kind: kind, ref: n.ref)) }
    }

    // MARK: Loading

    private func loadForge() async {
        let mine = asked
        detail = nil
        forgeProblem = nil
        guard place.kind.fromForge else { return }
        let machines = model.forgeMachines
        guard !machines.isEmpty else { forgeProblem = WorkList.noForgeHere; return }
        var last: String?
        for machine in machines {
            do {
                let got = try await model.forgeItem(node, cursor: nil, on: machine.id)
                guard asked == mine else { return }
                detail = (machine.id, got)
                return
            } catch {
                last = error.localizedDescription
            }
        }
        guard asked == mine else { return }
        forgeProblem = last ?? WorkList.notReadHere
    }

    /// The item again after a write (#3130), from the machine that read it, keeping the page
    /// as it is until the new one comes.
    private func reread() async {
        guard let had = detail else { return }
        do {
            let got = try await model.forgeItem(node, cursor: nil, on: had.host)
            detail = (had.host, got)
        } catch {
            forgeProblem = error.localizedDescription
        }
    }

    private func readOlder() async {
        guard let had = detail, let cursor = had.got.cursor else { return }
        olderLoading = true
        defer { olderLoading = false }
        do {
            let page = try await model.forgeItem(node, cursor: cursor, on: had.host)
            var got = had.got
            got.comments = page.comments + got.comments
            got.cursor = page.cursor
            detail = (had.host, got)
        } catch {
            forgeProblem = error.localizedDescription
        }
    }

    private func loadLineage() async {
        graph = nil
        layout = nil
        costs = [:]
        linksFailed = false
        reading = false
        guard let host = lineageHost else { return }
        let mine = LineageAsk(host: host, asked: asked)
        do {
            var walked = try await model.lineageWalk(node, on: host)
            guard LineageAsk(host: lineageHost, asked: asked) == mine else { return }
            graph = walked
            lay()
            var found: [DaemonAPI.LineageNode: DaemonAPI.LineageCostRollup] = [:]
            await withTaskGroup(of: DaemonAPI.LineageCostRollup?.self) { group in
                for n in Set(walked.nodes + [node]) where LineageList.costed(n) || n == node {
                    group.addTask { await model.lineageCost(n, on: host) }
                }
                for await rollup in group {
                    if let rollup { found[rollup.node] = rollup }
                }
            }
            guard LineageAsk(host: lineageHost, asked: asked) == mine else { return }
            costs = found
            lay()
            // The daemon resolves titles in the background (#3102): walk again while it says some are to come.
            reading = walked.resolving == true
            for _ in 0 ..< LineageList.resolvingAsks where walked.resolving == true {
                do {
                    try await Task.sleep(for: .seconds(1))
                    walked = try await model.lineageWalk(node, on: host)
                } catch {
                    break
                }
                guard LineageAsk(host: lineageHost, asked: asked) == mine else { return }
                graph = walked
                lay()
            }
            reading = false
        } catch {
            guard LineageAsk(host: lineageHost, asked: asked) == mine else { return }
            linksFailed = true
        }
    }

    private func lay() {
        layout = graph.map { LineageLayout.graph(of: node, graph: $0, costs: costs, title: { n in
            sessionID(n).flatMap { model.workSessionTitle($0) }
        }) }
    }
}
