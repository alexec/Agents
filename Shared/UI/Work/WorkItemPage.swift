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
            .padding(compact ? 16 : 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        #if os(iOS)
        .refreshable { asked += 1 }
        #endif
        .workTask(id: asked) { await loadForge() }
        .workTask(id: estimateAsk) { await loadEstimate() }
        #if os(macOS)
        .workTask(id: pipelineAsk) { await loadPipeline() }
        #endif
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

    /// The project the item was read for (#3283), when the person has more than one: with one, the
    /// page says nothing new.
    private var projectWords: String? {
        let projects = model.workProjects
        guard projects.count > 1, let detail else { return nil }
        return WorkList.project(ofFolder: detail.got.item.folder, on: detail.host, in: projects).map { WorkList.projectWords($0.name) }
    }

    private var header: some View {
        let item = detail?.got.item
        let labels = item?.labels ?? []
        let url = item?.url.flatMap(URL.init(string:)) ?? WorkList.url(node)
        let title = item?.title ?? ReportValueWords.name(node)
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
                WorkStatePill(state: item?.state ?? "", draft: item?.draft ?? false, status: item?.status)
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
            MarkdownText(markdown: ForgeMarkdown.markdown(got.body), remoteImage: image(on: host))
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
                    MarkdownText(markdown: ForgeMarkdown.markdown(c.body), remoteImage: image(on: host))
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
