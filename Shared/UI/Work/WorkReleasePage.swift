import AgentsKitCore
import SwiftUI

/// A release's page in the Work look (#4421, `specs/4328-work-look/milestones.md` notes 22 to
/// 29): the header with its Latest chip and Open on GitHub, the state line with the range to
/// the release before it, the notes, the pull requests in it, and the side panel (Tag, Compared
/// with, Pipeline, Lineage). Under 700 points the panel is a block of rows under the notes; on a
/// phone the pull requests are a row, **Pull requests · 23 ›**, that pushes their list (note 43,
/// #4422). It draws what lineage knows (`lineage/walk`, `lineage/cost`, `lineage/figures`); the forge's releases (#4426)
/// bring the name, the notes, the author, drafts and pre-releases.
struct WorkReleasePage: View {
    let model: any WorkModel
    let place: WorkPlace
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var compact: Bool { sizeClass == .compact }
    #else
    private let compact = false
    #endif
    @Environment(\.openURL) private var openURL

    @State private var graph: DaemonAPI.LineageGraph?
    @State private var rollup: DaemonAPI.LineageCostRollup?
    @State private var figures: DaemonAPI.LineageFigures?
    @State private var problem: String?
    @State private var reading = false
    @State private var asked = 0
    @State private var width: CGFloat = 0
    /// The pull requests' search and Label filter (note 25).
    @State private var filter = WorkList.Filter(state: .all)
    /// The phone's list of the pull requests is pushed (note 43).
    @State private var showsPulls = false

    private var node: DaemonAPI.LineageNode { place.node ?? .init(kind: WorkList.Kind.release.rawValue, ref: "") }
    private var tag: String { WorkReleaseLook.tag(node.ref) }
    private var list: WorkListState { model.workLists[.release] }
    private var row: WorkList.Row? { list.all.first { $0.node.ref == node.ref } }
    private var previous: WorkList.Row? { WorkReleaseLook.previous(of: node.ref, in: list.all) }
    private var isLatest: Bool { WorkReleaseLook.latest(list.all).contains(node.ref) }
    private var pulls: [WorkList.Row]? { graph.map { WorkReleaseLook.pullRequests(of: node, in: $0) } }
    private var forgeURL: URL? { row?.url ?? WorkList.url(node) }

    /// Lineage from This Mac, else the first machine that keeps links.
    private var lineageHost: MachineRef? { model.lineageMachines.first?.id }

    private var narrow: Bool { compact || (width > 0 && width < WorkSidePanel<EmptyView>.narrowUnder) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if let problem {
                    WorkErrorStrip(lines: [problem]) { asked += 1 }
                }
                Group {
                    if narrow {
                        notes
                        WorkSidePanel(compact: true) { panel }
                        if compact { pullsRow } else { pullRequests }
                    } else {
                        HStack(alignment: .top, spacing: 24) {
                            VStack(alignment: .leading, spacing: 16) {
                                notes
                                pullRequests
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            WorkSidePanel(compact: false) { panel }
                        }
                    }
                }
                .opacity(problem == nil ? 1 : 0.5)
            }
            .padding(compact ? 16 : 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onGeometryChange(for: CGFloat.self, of: \.size.width) { width = $0 }
        #if os(iOS)
        .refreshable { asked += 1 }
        .navigationDestination(isPresented: $showsPulls) {
            WorkReleasePulls(tag: tag, pulls: pulls ?? []) { ref in
                showsPulls = false
                model.showWork(WorkPlace(kind: .pr, ref: ref))
            }
            .paperGround()
        }
        .navigationSubtitle(model.workNeighbours.map { WorkList.positionWords($0, more: list.hasMore) } ?? "")
        .navigationBarBackButtonHidden(true)
        .toolbar { barItems }
        #else
        .toolbar { toolbar }
        .toolbar(removing: .title)
        #endif
        .workTask(id: asked) { await load() }
    }

    // MARK: Toolbar

    #if os(macOS)
    /// *Releases › v0.42.0* (Releases opens the list), then ↑ *2 of 28* ↓ and Refresh (note 22).
    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            HStack(spacing: 4) {
                Button(WorkList.Kind.release.title) { model.showWork(WorkPlace(kind: .release)) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("All releases")
                Image(systemName: "chevron.compact.right").foregroundStyle(.tertiary).accessibilityHidden(true)
                Text(tag).fontWeight(.semibold).monospacedDigit()
            }
            .appText(.reading)
            .lineLimit(1)
            .fixedSize()
        }
        ToolbarSpacer(.flexible)
        ToolbarItemGroup(placement: .primaryAction) {
            if let n = model.workNeighbours {
                HStack(spacing: 4) {
                    Button { Task { await model.stepWork(forward: false) } } label: { stepLabel("chevron.up") }
                        .disabled(n.previous == nil)
                        .help("Newer release")
                        .accessibilityLabel("Previous")
                    Text(WorkList.positionWords(n, more: list.hasMore))
                        .appText(.supporting).foregroundStyle(.secondary).monospacedDigit()
                        .lineLimit(1).fixedSize()
                    Button { Task { await model.stepWork(forward: true) } } label: { stepLabel("chevron.down") }
                        .disabled(!model.workHasNext || list.loadingMore)
                        .help("Older release")
                        .accessibilityLabel("Next")
                }
                .buttonStyle(.borderless)
            }
            WorkRefreshButton(running: reading) { asked += 1 }
        }
    }

    private func stepLabel(_ symbol: String) -> some View {
        Image(systemName: symbol).frame(width: 24, height: 24).contentShape(Rectangle())
    }
    #endif

    #if os(iOS)
    /// The Remote's bar: ‹ Releases, then ↑ and ↓, and on the iPhone Open on GitHub.
    @ToolbarContentBuilder
    private var barItems: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button { back() } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left").fontWeight(.semibold)
                    Text(WorkList.Kind.release.title)
                }
            }
            .accessibilityLabel(WorkList.Kind.release.title)
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            if let n = model.workNeighbours {
                Button { Task { await model.stepWork(forward: false) } } label: { Image(systemName: "chevron.up") }
                    .disabled(n.previous == nil)
                    .accessibilityLabel("Previous")
                Button { Task { await model.stepWork(forward: true) } } label: { Image(systemName: "chevron.down") }
                    .disabled(!model.workHasNext || list.loadingMore)
                    .accessibilityLabel("Next")
            }
            if compact, let url = forgeURL {
                Button { openURL(url) } label: { Image(systemName: "arrow.up.right.square") }
                    .accessibilityLabel(WorkList.openOnWords(node.ref))
            }
        }
    }

    private func back() {
        if model.workHistory.canGoBack { model.workHistory.back() } else { model.showWork(WorkPlace(kind: .release)) }
    }
    #endif

    // MARK: Header

    /// The name and its chip, then the state line: the box glyph, *released 2 h ago*, the range to
    /// the release before (a link to the forge's compare page), the count, and Open on GitHub.
    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text.forgeTitle(row?.title ?? tag).fontWeight(.semibold)
                    .appText(.title).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                if isLatest { WorkReleaseChip.latest.fixedSize() }
            }
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: WorkList.Kind.release.sidebarIcon).foregroundStyle(.secondary).accessibilityHidden(true)
                stateLine.appText(.supporting).foregroundStyle(.secondary).lineLimit(narrow ? 2 : 1)
                Spacer(minLength: 8)
                if !compact, let url = forgeURL {
                    Button { openURL(url) } label: {
                        Label(WorkList.openOnWords(node.ref), systemImage: "arrow.up.right.square")
                    }
                    .linkStyle()
                    .help(WorkList.openOnWords(node.ref))
                }
            }
        }
    }

    private var stateLine: Text {
        let words = WorkReleaseLook.stateWords(released: row?.updated, pulls: pulls?.count, compact: narrow)
        guard let previous else { return Text(words) }
        let before = WorkReleaseLook.tag(previous.node.ref)
        var range = AttributedString(WorkReleaseLook.rangeWords(from: before, to: tag))
        range.link = WorkReleaseLook.compareURL(node.ref, from: before)
        let ranged = Text(range).monospaced()
        return words.isEmpty ? ranged : Text("\(Text(words)) · \(ranged)")
    }

    // MARK: Main column

    /// The notes' box (note 24). Agents reads no notes yet (#4426): the box says where they are.
    private var notes: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Release notes").appText(.supporting).fontWeight(.semibold)
            HStack(spacing: 8) {
                Text(WorkReleaseLook.notesElsewhere(node.ref)).foregroundStyle(.secondary)
                if let url = forgeURL {
                    Button(WorkList.openOnWords(node.ref)) { openURL(url) }.linkStyle()
                }
            }
            .appText(.supporting)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Paper.Radius.card).fill(Paper.well))
        .overlay(RoundedRectangle(cornerRadius: Paper.Radius.card).strokeBorder(Paper.rule))
    }

    /// *Pull requests in this release* (note 25): a search field and Label, then a row per pull
    /// request lineage linked to it, with the merged glyph. A row opens the pull request's page.
    @ViewBuilder
    private var pullRequests: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                Text(pulls.map { "Pull requests in this release · \($0.count)" } ?? "Pull requests in this release")
                    .appText(.supporting).fontWeight(.semibold).monospacedDigit()
                Spacer(minLength: 8)
                if let pulls, !pulls.isEmpty {
                    WorkSearchField(prompt: "Filter pull requests", text: $filter.text).frame(width: compact ? 140 : 200)
                    let labels = WorkList.choices(pulls).labels
                    if !labels.isEmpty || !filter.label.isEmpty {
                        WorkFilterMenu(name: "Label", selection: $filter.label, options: labels, words: { $0 }, any: "", anyWords: "Any")
                    }
                }
            }
            if let pulls {
                let shown = WorkList.filter(pulls, filter)
                if pulls.isEmpty {
                    Text(WorkReleaseLook.noPulls).appText(.supporting).foregroundStyle(.secondary)
                } else if shown.isEmpty {
                    HStack(spacing: 8) {
                        Text("No pull requests match").foregroundStyle(.secondary)
                        Button(WorkLook.clearFilters) { filter = WorkList.Filter(state: .all) }.linkStyle()
                    }
                    .appText(.supporting)
                } else {
                    VStack(spacing: 0) {
                        ForEach(shown) { pr in
                            Button { model.showWork(WorkPlace(kind: .pr, ref: pr.id)) } label: {
                                WorkItemRow(row: pr, several: false, compact: narrow)
                                    .padding(.horizontal, 10).padding(.vertical, 4)
                            }
                            .buttonStyle(.plain)
                            if pr.id != shown.last?.id { Divider() }
                        }
                    }
                    .background(RoundedRectangle(cornerRadius: Paper.Radius.card).strokeBorder(Paper.rule))
                }
            } else {
                VStack(alignment: .leading, spacing: 8) { WorkPlaceholderRows(count: 4) }
                    .redacted(reason: .placeholder)
                    .accessibilityHidden(true)
            }
        }
    }

    #if os(iOS)
    /// The phone's **Pull requests · 23 ›** (note 43): a release is read for its notes, and its
    /// list of pull requests is long, so it is a page of its own.
    private var pullsRow: some View {
        Button { showsPulls = true } label: {
            HStack(spacing: 8) {
                Image(systemName: WorkList.Kind.pr.sidebarIcon).foregroundStyle(.secondary).accessibilityHidden(true)
                Text(pulls.map { "Pull requests · \($0.count)" } ?? "Pull requests").monospacedDigit()
                Spacer(minLength: 8)
                if pulls == nil { ProgressView().controlSize(.small) }
                Image(systemName: "chevron.right").foregroundStyle(.tertiary).accessibilityHidden(true)
            }
            .appText(.supporting)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(RoundedRectangle(cornerRadius: Paper.Radius.card).fill(Paper.well))
        .disabled(pulls == nil)
        .accessibilityLabel(pulls.map { WorkReleaseLook.pullsWords($0.count) } ?? "Pull requests")
    }
    #else
    private var pullsRow: some View { pullRequests }
    #endif

    // MARK: Side panel

    /// Tag, Compared with, Pipeline and Lineage (notes 26, 28 and 29).
    @ViewBuilder
    private var panel: some View {
        WorkSideSection(title: "Tag") {
            Label(tag, systemImage: "tag").monospaced().textSelection(.enabled)
        }
        WorkSideSection(title: "Compared with") {
            if let previous {
                let before = WorkReleaseLook.tag(previous.node.ref)
                Button { model.showWork(WorkPlace(kind: .release, ref: previous.id)) } label: {
                    Text(before).monospaced()
                }
                .linkStyle()
                .help("The release before this one")
            } else {
                WorkSideNone(words: "None")
            }
        }
        WorkSideSection(title: "Pipeline") {
            let stages = graph.map { WorkReleaseLook.pipeline(of: node, in: $0) } ?? []
            if stages.isEmpty {
                WorkSideNone(words: graph == nil ? "Reading…" : WorkReleaseLook.noPipeline)
            } else {
                ForEach(stages, id: \.self) { stage in
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark").fontWeight(.semibold).foregroundStyle(WorkLook.Tone.green.color)
                            .accessibilityLabel("Done")
                        if let url = stage.url {
                            Button(stage.words) { openURL(url) }.linkStyle()
                        } else {
                            Text(stage.words)
                        }
                    }
                }
            }
        }
        lineageSection
    }

    /// The cost, the sessions and how many run, the lead time (`lineage/figures`, #4427), the
    /// runtimes, then each session (it opens its chat, a green dot while it runs).
    @ViewBuilder
    private var lineageSection: some View {
        let sessions = WorkPlan.sessions(node, links: graph?.links ?? [], rollup: rollup)
        WorkSideSection(title: "Lineage") {
            if let words = figures.flatMap(WorkReleaseLook.lineageWords) ?? WorkLook.lineageWords(row?.lineage, compact: false) {
                Text(words).monospacedDigit()
            } else {
                WorkSideNone(words: WorkList.noAgentYet)
            }
            if let runtimes = figures.flatMap(WorkReleaseLook.runtimesWords) {
                Text(runtimes).appText(.fine).foregroundStyle(.secondary).monospacedDigit()
            }
            ForEach(sessions, id: \.self) { session(id: $0) }
        }
    }

    private func session(id: UUID) -> some View {
        let title = model.workSessionTitle(id)
        let runs = model.workSessionState(id)?.holdsRuntime == true
        return Button { model.openWorkSession(id) } label: {
            HStack(spacing: 6) {
                Circle().fill(runs ? WorkLook.Tone.green.color : Color.secondary.opacity(0.4)).frame(width: 7, height: 7)
                    .accessibilityHidden(true)
                Text(title ?? "A session on another machine").lineLimit(1).truncationMode(.tail)
                    .foregroundStyle(title == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(title == nil)
        .accessibilityLabel([title ?? "A session on another machine", runs ? "running" : nil].compactMap { $0 }.joined(separator: ", "))
    }

    // MARK: Loading

    /// The release's links (its pull requests, CI runs and deploys) and its cost, from the machine
    /// that keeps links. A refresh keeps the page as it is until the new read comes.
    private func load() async {
        let mine = asked
        guard let host = lineageHost, !node.ref.isEmpty else {
            graph = DaemonAPI.LineageGraph()
            return
        }
        reading = true
        defer { if asked == mine { reading = false } }
        async let cost = model.lineageCost(node, on: host)
        // A host before #4427 has no lineage/figures: the row's own figures stand in.
        async let figured = try? model.forge(DaemonAPI.Method.lineageFigures, DaemonAPI.LineageNodeRequest(node: node),
                                             returning: DaemonAPI.LineageFigures.self, on: host)
        do {
            let walked = try await model.lineageWalk(node, depth: 2, on: host)
            let (rolled, got) = await (cost, figured)
            guard asked == mine else { return }
            graph = walked
            rollup = rolled
            figures = got
            problem = nil
        } catch {
            _ = await (cost, figured)
            guard asked == mine else { return }
            if graph == nil { graph = DaemonAPI.LineageGraph() }
            problem = WorkList.failureWords(error)
        }
    }
}

/// A release's chip after its name (note 19): *Latest* in green; *Pre-release* and *Draft* come
/// with the forge's releases (#4426).
struct WorkReleaseChip: View {
    let words: String
    let color: Color

    static let latest = WorkReleaseChip(words: "Latest", color: WorkLook.Tone.green.color)

    var body: some View {
        Text(words)
            .appText(.fine)
            .fontWeight(.medium)
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 1)
            .overlay(Capsule().strokeBorder(color.opacity(0.6)))
    }
}

#if os(iOS)
/// A release's pull requests on a phone (note 43), pushed from its page: the search field in the
/// bar, then a phone row for each; a row opens the pull request's page.
private struct WorkReleasePulls: View {
    let tag: String
    let pulls: [WorkList.Row]
    let open: (String) -> Void
    @State private var filter = WorkList.Filter(state: .all)

    var body: some View {
        let shown = WorkList.filter(pulls, filter)
        List {
            if pulls.isEmpty {
                Text(WorkReleaseLook.noPulls).appText(.supporting).foregroundStyle(.secondary)
            } else if shown.isEmpty {
                HStack(spacing: 8) {
                    Text("No pull requests match").foregroundStyle(.secondary)
                    Button(WorkLook.clearFilters) { filter = WorkList.Filter(state: .all) }.linkStyle()
                }
                .appText(.supporting)
            }
            ForEach(shown) { pr in
                Button { open(pr.id) } label: { WorkItemRow(row: pr, several: false, compact: true) }
                    .buttonStyle(.plain)
            }
        }
        .listStyle(.inset)
        .searchable(text: $filter.text, prompt: "Filter pull requests")
        .navigationTitle("Pull requests")
        .navigationSubtitle(tag)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            let labels = WorkList.choices(pulls).labels
            if !labels.isEmpty || !filter.label.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    WorkFilterMenu(name: "Label", selection: $filter.label, options: labels, words: { $0 }, any: "", anyWords: "Any",
                                   compact: true)
                }
            }
        }
    }
}
#endif
