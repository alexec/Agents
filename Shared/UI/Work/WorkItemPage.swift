import AgentsKitCore
import SwiftUI

/// The page of one issue, pull request, milestone or release (#3119), as the web page's
/// `#/work/<kind>/<ref>`: the item from its forge (`forge/issue`, `forge/pull`) on the first
/// machine that reads it. It opens for any item, also one no agent touched. An issue's and a pull
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
    @State private var estimate: DaemonAPI.LineageEstimate?
    @State private var estimateRange = false
    @State private var pipeline: [Pipeline.Step] = []
    @State private var asked = 0
    @State private var width: CGFloat = 0

    private var node: DaemonAPI.LineageNode { place.node ?? .init(kind: place.kind.rawValue, ref: "") }

    /// Lineage from the machine that read the forge, else This Mac, else the first that keeps links.
    private var lineageHost: MachineRef? {
        let machines = model.lineageMachines
        if let host = detail?.host, machines.contains(where: { $0.id == host }) { return host }
        return machines.first?.id
    }

    /// The side panel goes beside the page on a wide one, and under the header on a narrow one (#4391).
    private var narrow: Bool { compact || (width > 0 && width < WorkSidePanel<EmptyView>.narrowUnder) }

    var body: some View {
        ScrollView {
            Group {
                if narrow {
                    VStack(alignment: .leading, spacing: 16) {
                        header
                        if let detail { panel(detail.got, compact: true) }
                        main
                    }
                } else {
                    VStack(alignment: .leading, spacing: 16) {
                        header
                        HStack(alignment: .top, spacing: 24) {
                            VStack(alignment: .leading, spacing: 16) { main }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if let detail { panel(detail.got, compact: false) }
                        }
                    }
                }
            }
            .padding(compact ? 16 : 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onGeometryChange(for: CGFloat.self, of: \.size.width) { width = $0 }
        #if os(iOS)
        .refreshable { asked += 1 }
        #endif
        .workTask(id: asked) { await loadForge() }
        .workTask(id: estimateAsk) { await loadEstimate() }
        #if os(macOS)
        .workTask(id: pipelineAsk) { await loadPipeline() }
        #endif
    }

    @ViewBuilder
    private var main: some View {
        if let detail, model.forgeWrites(on: detail.host) {
            WorkItemActions(model: model, host: detail.host, detail: detail.got, wrote: { Task { await reread() } })
        }
        if let forgeProblem {
            WorkErrorStrip(lines: [forgeProblem]) { asked += 1 }
        } else if place.kind.fromForge, detail == nil {
            ProgressView()
        }
        #if os(macOS)
        // An epic's plan (#3268): Mac + web, so not on the Remote (#2796).
        if let detail, WorkPlan.hasPlan(detail.got.item) {
            WorkPlanSection(model: model, host: detail.host, lineageHost: lineageHost, detail: detail.got, asked: asked,
                            estimates: estimate?.children ?? [],
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
    }

    // MARK: Side panel

    /// Assignees, Labels, Milestone, Repo, Project and Linked (#4391, parts.md section 5), as the
    /// wire has them now: avatars, the children and the pull requests that fix it come with #4363 and #4373.
    private func panel(_ got: DaemonAPI.ForgeItemDetail, compact: Bool) -> some View {
        let item = got.item
        return WorkSidePanel(compact: compact) {
            WorkSideSection(title: "Assignees") {
                if item.assignees.isEmpty {
                    WorkSideNone(words: "No one")
                } else {
                    ForEach(item.assignees, id: \.self) { WorkSidePerson(login: $0) }
                }
            }
            WorkSideSection(title: "Labels") {
                if item.labels.isEmpty {
                    WorkSideNone(words: "None")
                } else {
                    WrappingHStack(spacing: 4) {
                        ForEach(item.labels, id: \.name) { label in
                            WorkLabelChip(label: label, pick: pickLabel)
                        }
                    }
                }
            }
            WorkSideSection(title: "Milestone") {
                if let milestone = item.milestone {
                    Label(milestone, systemImage: "flag")
                } else {
                    WorkSideNone(words: "None")
                }
            }
            WorkSideSection(title: "Repo") {
                Text(WorkList.repoName(WorkList.repo(of: item.node.ref))).lineLimit(1).textSelection(.enabled)
            }
            if let projectName {
                WorkSideSection(title: "Project") { Text(projectName).lineLimit(1) }
            }
            if item.parent != nil || item.progress != nil {
                WorkSideSection(title: "Linked") {
                    if let parent = item.parent {
                        WorkSideLinked(node: parent) {
                            if let kind = WorkList.kind(of: parent) { model.showWork(WorkPlace(kind: kind, ref: parent.ref)) }
                        }
                    }
                    if let progress = item.progress {
                        ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                        Text("\(progress.done) of \(progress.total) closed").appText(.fine).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }
        }
    }

    /// A chip on the panel opens the list with that label (Mac); on a phone the chips are words.
    private var pickLabel: ((String) -> Void)? {
        #if os(macOS)
        { [model, place] name in
            let list = model.workLists[place.kind]
            list.filter.label = name
            model.showWork(WorkPlace(kind: place.kind))
        }
        #else
        nil
        #endif
    }

    private var projectName: String? {
        let projects = model.workProjects
        guard projects.count > 1, let detail else { return nil }
        return WorkList.project(ofFolder: detail.got.item.folder, on: detail.host, in: projects)?.name
    }

    private struct LineageAsk: Equatable {
        var host: MachineRef?
        var asked: Int
    }

    /// An issue's estimate (#3560), from the machine that keeps its links: an open one's, and a
    /// closed one's as it was when its work started, against what it took (#3561).
    private var estimateAsk: LineageAsk? {
        guard let item = detail?.got.item, item.node.kind == "issue" else { return nil }
        return LineageAsk(host: lineageHost, asked: asked)
    }

    /// The outer loop in reach of an issue, a PR or a release (#3588), from the machine that keeps
    /// its links: Mac + web, so not on the Remote (#2796).
    private var pipelineAsk: LineageAsk? {
        guard [.issue, .pr, .release].contains(place.kind), !node.ref.isEmpty else { return nil }
        return LineageAsk(host: lineageHost, asked: asked)
    }

    private var isOpen: Bool { detail?.got.item.state == "open" }

    // MARK: Header

    private var header: some View {
        let item = detail?.got.item
        let url = item?.url.flatMap(URL.init(string:)) ?? WorkList.url(node)
        let title = item?.title ?? ReportValueWords.name(node)
        return VStack(alignment: .leading, spacing: 6) {
            if compact {
                // A phone has no room beside the title: All and Refresh go above it.
                HStack(spacing: 16) { pageLinks }
                titleLine(title)
            } else {
                // Beside the title only when it keeps a readable width; in a narrow pane (an
                // iPad's detail, a narrow Mac window) they go above it, as on a phone (#4082).
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        titleLine(title)
                            .frame(minWidth: 320, idealWidth: 320, maxWidth: .infinity, alignment: .leading)
                        pageLinks
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 16) { pageLinks }
                        titleLine(title)
                    }
                }
            }
            // The state, the ref, who opened it and the comments; the rest is the side panel's (#4391).
            (compact ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4)) : AnyLayout(HStackLayout(spacing: 6))) {
                HStack(spacing: 6) {
                    WorkStatePill(state: item?.state ?? "", draft: item?.draft ?? false, status: item?.status)
                    Text(([node.ref] + [item?.author.map { "by \($0)" }, item.flatMap { $0.comments > 0 ? commentsWords($0.comments) : nil }]
                        .compactMap { $0 }).joined(separator: " · "))
                    .appText(.supporting).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                }
                if let url {
                    Button(WorkList.openOnWords(node.ref)) { openURL(url) }.linkStyle()
                }
            }
            if let estimate, isOpen, EstimateWords.shows(estimate) {
                estimateLine(estimate)
            } else if let estimate, !isOpen, let words = EstimateWords.actualWords(estimate) {
                Text(words).appText(.supporting).foregroundStyle(.secondary).monospacedDigit()
                #if os(macOS)
                    .textSelection(.enabled)
                #endif
            }
            #if os(macOS)
            if !pipeline.isEmpty { pipelineLine }
            #endif
            if let item, item.node.kind == "pr" {
                let words = [WorkList.checksWords(detail?.got.checks, summary: item.checks), WorkList.reviewWords(item.review)]
                    .compactMap { $0 }
                if !words.isEmpty {
                    Text(words.joined(separator: " · ")).appText(.supporting)
                }
            }
        }
    }

    private func commentsWords(_ n: Int) -> String { n == 1 ? "1 comment" : "\(n) comments" }

    /// "Estimate: about $3.20, 45K output tokens, 2h 10m of work (from 31 closed stories)", and for
    /// an epic what its closed children spent. The range is its help on the Mac; on the Remote a
    /// tap shows it under the line.
    @ViewBuilder
    private func estimateLine(_ e: DaemonAPI.LineageEstimate) -> some View {
        let range = EstimateWords.rangeWords(e)
        let line = Text(([EstimateWords.line(e)] + [EstimateWords.spentWords(e)].compactMap { $0 }).joined(separator: " · "))
            .appText(.supporting).foregroundStyle(.secondary).monospacedDigit()
            .accessibilityHint(range ?? "")
        #if os(iOS)
        line.onTapGesture { if range != nil { estimateRange.toggle() } }
        if estimateRange, let range {
            Text(range).appText(.fine).foregroundStyle(.secondary).monospacedDigit()
        }
        #else
        line.textSelection(.enabled).help(range ?? "")
        #endif
    }

    /// "Release v1.2.0 · CI run · TestFlight 42 · Sentry issue 4321", each a link out (#3588).
    private var pipelineLine: some View {
        var line = AttributedString()
        for (i, step) in pipeline.enumerated() {
            if i > 0 { line += AttributedString(" · ") }
            var words = AttributedString(step.words)
            words.link = step.url
            line += words
        }
        return Text(line).appText(.supporting).foregroundStyle(.secondary).monospacedDigit()
    }

    /// The title and its number as one text, so the number wraps with the title rather than
    /// taking a column of its own (#4082).
    private func titleLine(_ title: String) -> some View {
        var line = Text.forgeTitle(title).fontWeight(.semibold)
        if !WorkList.titleSaysRef(title, node.ref) {
            line = Text("\(line) \(Text(WorkList.shortRef(node.ref)).fontWeight(.regular).foregroundStyle(.secondary))")
        }
        return line.appText(.title).textSelection(.enabled)
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
            MarkdownText(markdown: ForgeMarkdown.markdown(got.body), remoteImage: image(on: host))
        }
        if !got.comments.isEmpty || got.cursor != nil {
            Text("Comments").appText(.reading).fontWeight(.semibold).padding(.top, 8)
            if got.cursor != nil {
                Button(olderLoading ? "Loading…" : "Older comments") { Task { await readOlder() } }
                    .linkStyle()
                    .disabled(olderLoading)
            }
            // Each on the timeline's line, with its avatar (#4391).
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(got.comments.enumerated()), id: \.offset) { _, c in
                    WorkCommentView(comment: c) {
                        MarkdownText(markdown: ForgeMarkdown.markdown(c.body), remoteImage: image(on: host))
                    }
                }
            }
        }
        if model.forgeWrites(on: host) {
            WorkCommentBox(model: model, host: host, node: got.item.node, wrote: { Task { await reread() } })
                .padding(.top, 8)
        }
    }

    /// An image in the body or a comment, read by the machine that read the item (#4010,
    /// `forge/image`), so the app never loads the page's remote URL. Nil when it cannot.
    private func image(on host: MachineRef) -> RemoteImageLoader {
        { [model] url in
            guard let got = try? await model.forge(DaemonAPI.Method.forgeImage, DaemonAPI.ForgeImageRequest(url: url.absoluteString),
                                                   returning: DaemonAPI.ForgeImage.self, on: host) else { return nil }
            return PlatformImage(data: got.data)
        }
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

    private func loadPipeline() async {
        let mine = pipelineAsk
        pipeline = []
        guard let mine, let host = mine.host,
              let graph = try? await model.lineageWalk(node, depth: Pipeline.depth, on: host) else { return }
        guard pipelineAsk == mine else { return }
        pipeline = Pipeline.steps(of: node, in: graph)
    }

    private func loadEstimate() async {
        let mine = estimateAsk
        estimate = nil
        guard let mine, let host = mine.host else { return }
        let got = await model.lineageEstimate(node, on: host)
        guard estimateAsk == mine else { return }
        estimate = got
    }
}
