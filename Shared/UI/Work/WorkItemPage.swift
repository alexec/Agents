import AgentsKitCore
import SwiftUI

/// The page of one issue, pull request or release (#3119), as the web page's
/// `#/work/<kind>/<ref>`: the item from its forge (`forge/issue`, `forge/pull`) on the first
/// machine that reads it. It opens for any item, also one no agent touched. An issue's page is in
/// the Work look (#4400, `specs/4328-work-look/issue.md`): the header with Start Agent, one
/// timeline (the body, then the comments), the comment box with Close or Reopen, and the side
/// panel (Assignees, Labels with its gear, Repo, Linked, Lineage and, on the Mac, Docs).
/// A pull request's page (#4406, `specs/4328-work-look/pull-request.md`) has Files changed in
/// place of Start Agent, the merge box at the end of the timeline (at the top of a narrow page),
/// Close or Reopen pull request in the comment box, and Reviewers and Branch on the panel.
/// On the Mac the place, Previous and Next, and Refresh are the toolbar's. Its writes (#3130) go to
/// the machine that read it.
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
    @State private var reading = false
    /// The item on screen came from this device's copy (#4930): no writes until its machine answers.
    @State private var fromDevice = false
    @State private var olderLoading = false
    @State private var estimate: DaemonAPI.LineageEstimate?
    @State private var estimateRange = false
    @State private var forecast: DaemonAPI.LineageForecast?
    @State private var forecastHelp = false
    @State private var pipeline: [Pipeline.Step] = []
    @State private var lineage: (cost: DaemonAPI.LineageCostRollup?, sessions: [UUID])?
    @State private var said: (words: String, failed: Bool)?
    @State private var writing = false
    @State private var pickingLabels = false
    @State private var asked = 0
    @State private var width: CGFloat = 0

    private var node: DaemonAPI.LineageNode { place.node ?? .init(kind: place.kind.rawValue, ref: "") }

    /// Lineage from the machine that read the forge, else This Mac, else the first that keeps links.
    private var lineageHost: MachineRef? {
        let machines = model.lineageMachines
        if let host = detail?.host, machines.contains(where: { $0.id == host }) { return host }
        return machines.first?.id
    }

    /// Under 700 points (a phone, an iPad in portrait, a narrow Mac window) the side panel is a
    /// block of rows under the header, and Linked, Lineage and Docs go after the comment box (#4400).
    private var narrow: Bool { compact || (width > 0 && width < WorkSidePanel<EmptyView>.narrowUnder) }

    private var item: DaemonAPI.ForgeItem? { detail?.got.item }
    private var isIssue: Bool { place.kind == .issue }
    /// The row the page was opened from, while the read runs: its title, number and state show at once.
    private var row: WorkList.Row? {
        guard detail == nil, !node.ref.isEmpty else { return nil }
        return model.workLists[place.kind].all.first { $0.node.ref == node.ref }
    }

    /// The person's machine that read it takes writes: else no Start Agent, comment box or gears.
    /// None while the page is this device's copy (#4930): a write acts on the machine's own answer.
    private var writes: Bool { !fromDevice && (detail.map { model.forgeWrites(on: $0.host) } ?? false) }

    var body: some View {
        ScrollView {
            Group {
                if detail == nil, let forgeProblem {
                    couldNotRead(forgeProblem)
                } else if narrow {
                    VStack(alignment: .leading, spacing: 16) {
                        header
                        problemStrip
                        Group {
                            if let detail, let box = WorkLook.mergeBox(detail.got) {
                                mergeBox(box, detail.got, on: detail.host)
                            }
                            if let detail, detail.got.item.node.kind == "pr" {
                                WorkFilesChanged(model: model, host: detail.host, detail: detail.got, compact: true)
                            }
                            // An epic's Plan before the panel's rows: it is what a person opens an epic for (epic.md note 15).
                            plan
                            sidePanel(compact: true) { details }
                            main
                            if detail != nil {
                                sidePanel(compact: true) { connections }
                            }
                        }
                        .opacity(forgeProblem == nil ? 1 : 0.5)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 16) {
                        header
                        problemStrip
                        HStack(alignment: .top, spacing: 24) {
                            VStack(alignment: .leading, spacing: 16) {
                                plan
                                main
                            }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            sidePanel(compact: false) {
                                details
                                connections
                            }
                        }
                        .opacity(forgeProblem == nil ? 1 : 0.5)
                    }
                }
            }
            .padding(compact ? 16 : 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onGeometryChange(for: CGFloat.self, of: \.size.width) { width = $0 }
        .environment(\.workPictures, detail.map { WorkPictures(model: model, host: $0.host) })
        #if os(iOS)
        .refreshable { asked += 1 }
        .navigationSubtitle(model.workNeighbours.map { WorkList.positionWords($0, more: model.workLists[place.kind].hasMore) } ?? "")
        // ‹ Issues takes the split view's own back: from the list, that goes on to the sidebar.
        .navigationBarBackButtonHidden(true)
        .toolbar { barItems }
        #else
        .toolbar { toolbar }
        // The place says Issues › #12: the window's own title, Issues, would say it twice.
        .toolbar(removing: .title)
        #endif
        .workTask(id: asked) { await loadForge() }
        .workTask(id: estimateAsk) { await loadEstimate() }
        .workTask(id: forecastAsk) { await loadForecast() }
        .workTask(id: lineageAsk) { await loadLineage() }
        #if os(macOS)
        .workTask(id: pipelineAsk) { await loadPipeline() }
        #endif
    }

    // MARK: Toolbar (Mac)

    #if os(macOS)
    /// The place, *Issues › #4331* (Issues opens the list), then Previous and Next and Refresh at
    /// the toolbar's end, as the list has Refresh (#4400 notes 1 to 3).
    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            HStack(spacing: 4) {
                Button(place.kind.title) { model.showWork(WorkPlace(kind: place.kind)) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("All \(place.kind.title.lowercased())")
                Image(icon: "chevron.compact.right").foregroundStyle(.tertiary).accessibilityHidden(true)
                Text(WorkList.shortRef(node.ref)).fontWeight(.semibold).monospacedDigit()
            }
            .appText(.reading)
            .lineLimit(1)
            .fixedSize()
        }
        // With no title in the toolbar, they would follow the place: the spacer keeps them at its end.
        ToolbarSpacer(.flexible)
        ToolbarItemGroup(placement: .primaryAction) {
            stepper
            WorkRefreshButton(running: reading) { asked += 1 }
        }
    }
    #endif

    #if os(iOS)
    /// The Remote's bar (#4401 notes 1, 2 and 7): ‹ Issues, the number with *3 of 42* under it,
    /// then ↑ and ↓, and on the iPhone Open on GitHub, as the state line has no room for it.
    @ToolbarContentBuilder
    private var barItems: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            // An HStack, not a Label: the bar draws a Label's icon alone.
            Button { back() } label: {
                HStack(spacing: 4) {
                    Image(icon: "chevron.left").fontWeight(.semibold)
                    Text(backWords)
                }
            }
            .accessibilityLabel(backWords)
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            if let n = model.workNeighbours {
                let list = model.workLists[place.kind]
                Button { Task { await model.stepWork(forward: false) } } label: { Image(toolbarIcon: "chevron.up") }
                    .disabled(n.previous == nil)
                    .accessibilityLabel("Previous")
                Button { Task { await model.stepWork(forward: true) } } label: {
                    if list.loadingMore { ProgressView() } else { Image(toolbarIcon: "chevron.down") }
                }
                .disabled(!model.workHasNext || list.loadingMore)
                .accessibilityLabel("Next")
            }
            if compact, let url = forgeURL {
                Button { openURL(url) } label: { Image(toolbarIcon: "arrow.up.right.square") }
                    .accessibilityLabel(WorkList.openOnWords(node.ref))
            }
        }
    }

    /// Back to the place before, the list when it was one; else to the list (a page opened from a link).
    private var backWords: String {
        let history = model.workHistory
        guard history.canGoBack, let ref = history.places[history.at - 1].ref else { return place.kind.title }
        return WorkList.shortRef(ref)
    }

    private func back() {
        if model.workHistory.canGoBack { model.workHistory.back() } else { model.showWork(WorkPlace(kind: place.kind)) }
    }
    #endif

    private var forgeURL: URL? { item?.url.flatMap(URL.init(string:)) ?? row?.url ?? WorkList.url(node) }

    // MARK: Header

    private var header: some View {
        let title = item?.title ?? row?.title
        return VStack(alignment: .leading, spacing: 8) {
            if narrow {
                titleLine(title)
                stateLine
                if isEpic { leadButton.frame(maxWidth: .infinity) }
                if let start = startOffer { startButton(start).frame(maxWidth: .infinity) }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    titleLine(title).frame(maxWidth: .infinity, alignment: .leading)
                    if isEpic { leadButton }
                    if let start = startOffer { startButton(start) }
                    if let detail, detail.got.item.node.kind == "pr" {
                        WorkFilesChanged(model: model, host: detail.host, detail: detail.got)
                    }
                }
                stateLine
            }
        }
        .redacted(reason: title == nil ? .placeholder : [])
    }

    /// The title in the title style, semibold, its number after it in the regular weight and the
    /// secondary colour, as one text, so the number wraps with the title (#4082). Never cut.
    private func titleLine(_ title: String?) -> some View {
        let title = title ?? "An issue's title, while the page reads it"
        var line = Text.forgeTitle(title).fontWeight(.semibold)
        if !WorkList.titleSaysRef(title, node.ref) {
            line = Text("\(line) \(Text(WorkList.shortRef(node.ref)).fontWeight(.regular).foregroundStyle(.secondary))")
        }
        return line.appText(.title).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
    }

    /// The state pill (a tracker's status menu in its place), *alexec opened this 3 d ago · 4
    /// comments*, and Open on GitHub at the trailing end.
    private var stateLine: some View {
        // On the iPhone Open on GitHub is the bar's (#4401 note 7).
        let url = compact ? nil : forgeURL
        return HStack(alignment: .center, spacing: 8) {
            if let item, let transitions = detail?.got.transitions, writes {
                WorkStatusMenu(item: item, transitions: transitions) { transition in
                    act(DaemonAPI.Method.forgeClose, DaemonAPI.ForgeCloseRequest(node: item.node, transition: transition))
                }
            } else {
                WorkPagePill(kind: node.kind, state: item?.state ?? row?.state ?? "", draft: item?.draft ?? row?.draft ?? false,
                             status: item?.status ?? row?.status, stateReason: item?.stateReason ?? row?.stateReason)
            }
            if item?.standing == true {
                // A standing epic never closes (#3662, epic.md note 16).
                Text("Standing").appText(.fine).fontWeight(.medium).foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(Capsule().fill(Paper.well))
                    .overlay(Capsule().strokeBorder(Paper.rule))
            }
            Text(stateWords).appText(.supporting).foregroundStyle(.secondary).lineLimit(narrow ? 2 : 1).textSelection(.enabled)
            Spacer(minLength: 8)
            if let url {
                Button { openURL(url) } label: {
                    Label(WorkList.openOnWords(node.ref), icon: "arrow.up.right.square")
                }
                .linkStyle()
                .help(WorkList.openOnWords(node.ref))
                .accessibilityLabel(WorkList.openOnWords(node.ref))
            }
        }
    }

    /// "alexec opened this 3 d ago · closed 1 d ago · 4 comments"; narrow: "alexec · 3 d · 4
    /// comments". With no opened time from the forge, the last update's (#4373).
    private var stateWords: String {
        let author = item?.author ?? row?.author
        let updated = item?.updatedAt ?? row?.updated
        let comments = item?.comments ?? row?.comments ?? 0
        let state = item?.state ?? row?.state ?? "open"
        let created = item?.createdAt ?? row?.created
        let closed = item?.closedAt ?? row?.closed
        if node.kind == "pr" {
            return WorkLook.pullStateWords(author: author, state: state, updated: updated, comments: comments, narrow: narrow,
                                           created: created, closed: closed)
        }
        return WorkLook.issueStateWords(author: author, state: state, updated: updated, comments: comments, narrow: narrow,
                                        created: created, closed: closed)
    }

    /// Start Agent: on an open issue whose read gives a `start` (one in a folder), when a machine
    /// of the person's can write. A closed one has none (#4400, states); an epic has Start lead in
    /// its place (#4416).
    private var startOffer: DaemonAPI.ForgeStart? {
        guard isIssue, !isEpic, writes, item?.state == "open" else { return nil }
        return detail?.got.start
    }

    /// An epic's page (#3268): it has a Plan, and Start lead or Open lead in the header.
    private var isEpic: Bool { item.map(WorkPlan.hasPlan) ?? false }

    /// An epic's one action (epic.md note 1): with a lead, Open lead (bordered, with a dot for its
    /// state), which opens its chat; with none, on an open epic a machine writes to, Start lead
    /// (prominent), the new-session form in the epic's folder filled in for the lead skill.
    @ViewBuilder
    private var leadButton: some View {
        if let lead = model.workLead(of: node) {
            Button { model.openWorkSession(lead.id) } label: {
                HStack(spacing: 6) {
                    Label("Open lead", icon: "person")
                    Circle().fill(leadDot(lead.state)).frame(width: 7, height: 7).accessibilityHidden(true)
                }
                .frame(maxWidth: narrow ? .infinity : nil)
            }
            .buttonStyle(.bordered)
            .controlSize(compact ? .large : .regular)
            .help("The lead's chat")
            .accessibilityValue(WorkPlan.leadWords(lead.state))
        } else if writes, item?.state == "open", let start = detail?.got.start {
            Button { startLead(start) } label: {
                Label("Start lead", icon: "sparkle").frame(maxWidth: narrow ? .infinity : nil)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(compact ? .large : .regular)
            .help("The new-session form in this epic's folder, filled in for a lead with the lead skill")
        }
    }

    private func leadDot(_ state: AgentState) -> Color {
        switch state {
        case .waitingOnUser: Paper.forgeWaiting
        case .starting, .running: WorkLook.Tone.green.color
        default: Color.secondary.opacity(0.5)
        }
    }

    private func startLead(_ start: DaemonAPI.ForgeStart) {
        guard let detail else { return }
        guard let folder = detail.got.item.folder else {
            said = ("No folder on this machine is on this issue's repo.", true)
            return
        }
        let lead = WorkPlan.leadStart(start, url: detail.got.item.url)
        let offer = AppViewStart(prompt: lead.prompt, labels: lead.labels, worktree: lead.worktree)
        if let why = model.offerStart(offer, in: FolderKey(host: detail.host, folder: URL(fileURLWithPath: folder))) {
            said = (why, true)
        }
    }

    private func startButton(_ start: DaemonAPI.ForgeStart) -> some View {
        Button { startAgent(start) } label: {
            Label("Start Agent", icon: "sparkle").frame(maxWidth: narrow ? .infinity : nil)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(compact ? .large : .regular)
        .help("The new-agent form in this issue's folder, filled in for it")
    }

    private func startAgent(_ start: DaemonAPI.ForgeStart) {
        guard let detail else { return }
        guard let folder = detail.got.item.folder else {
            said = ("No folder on this machine is on this issue's repo.", true)
            return
        }
        let offer = AppViewStart(prompt: start.prompt, labels: start.labels, worktree: start.worktree)
        if let why = model.offerStart(offer, in: FolderKey(host: detail.host, folder: URL(fileURLWithPath: folder))) {
            said = (why, true)
        }
    }

    #if os(macOS)
    /// Previous and Next through the list the page was opened from (#3257), and where it stands
    /// in it: ↑ *3 of 42* ↓. None on a page opened from a link or an address. The Remote's are its bar's.
    @ViewBuilder
    private var stepper: some View {
        if let n = model.workNeighbours {
            let list = model.workLists[place.kind]
            HStack(spacing: 4) {
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

    /// An arrow with a target a pointer finds.
    private func stepLabel(_ symbol: String) -> some View {
        Image(icon: symbol).frame(width: 24, height: 24).contentShape(Rectangle())
    }
    #endif

    // MARK: States

    /// A read failed after one came: a strip under the header, the last read dimmed under it.
    @ViewBuilder
    private var problemStrip: some View {
        if detail != nil, let forgeProblem {
            WorkErrorStrip(lines: [forgeProblem]) { asked += 1 }
        }
        WorkFromDeviceStrip(on: fromDevice && forgeProblem == nil)
    }

    /// Nothing read: in the middle, the warning glyph, *Could not read #4331*, the forge's words,
    /// Try again and Open on GitHub.
    private func couldNotRead(_ words: String) -> some View {
        VStack(spacing: 8) {
            Image(icon: "exclamationmark.triangle")
                // The state's own glyph, larger than any text step: a marked decorative glyph.
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Could not read \(WorkList.shortRef(node.ref))").appText(.reading).fontWeight(.semibold)
            Text(words).appText(.supporting).foregroundStyle(.secondary).multilineTextAlignment(.center).textSelection(.enabled)
            HStack(spacing: 12) {
                Button(WorkLook.tryAgain) { asked += 1 }.buttonStyle(.paper)
                if let url = forgeURL {
                    Button(WorkList.openOnWords(node.ref)) { openURL(url) }.linkStyle()
                }
            }
            .padding(.top, 4)
        }
        .padding(.vertical, 60)
        .frame(maxWidth: .infinity)
    }

    // MARK: Main column

    /// An epic's plan (#3268), above the timeline; on a narrow page above the panel's rows too (#4417).
    @ViewBuilder
    private var plan: some View {
        if let detail, WorkPlan.hasPlan(detail.got.item) {
            WorkPlanSection(model: model, host: detail.host, lineageHost: lineageHost, detail: detail.got, asked: asked,
                            estimates: estimate?.children ?? [], compact: compact,
                            writes: writes, waiting: fromDevice, wrote: { Task { await reread() } })
        }
    }

    @ViewBuilder
    private var main: some View {
        if let detail {
            timeline(detail.got, on: detail.host)
        } else if place.kind.fromForge {
            placeholderBody
        }
    }

    /// The body box while the page reads, as a placeholder: no spinner.
    private var placeholderBody: some View {
        WorkCommentView(comment: .init(author: "author", body: "", at: Date()), words: "opened this", compact: narrow) {
            Text("The issue's description, while the page reads it. It takes a few lines here.")
        }
        .redacted(reason: .placeholder)
        .accessibilityHidden(true)
    }

    /// One timeline (#4400 notes 8 to 11): the body is its first box, Older comments under it,
    /// then the comments and the forge's events in time order (#4373); a closed item's close,
    /// from its state where the forge gives no events; then the comment box.
    @ViewBuilder
    private func timeline(_ got: DaemonAPI.ForgeItemDetail, on host: MachineRef) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            WorkCommentView(comment: .init(author: got.item.author ?? WorkList.forgeName(node.ref), body: got.body,
                                           at: got.item.createdAt ?? got.item.updatedAt, avatar: got.item.authorAvatar),
                            words: "opened this", compact: narrow) {
                if got.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("No description.").foregroundStyle(.secondary)
                } else {
                    MarkdownText(markdown: ForgeMarkdown.markdown(got.body), remoteImage: image(on: host))
                }
            }
            if got.cursor != nil {
                olderComments
            }
            ForEach(Array(WorkLook.timeline(comments: got.comments, events: got.events, older: got.cursor != nil).enumerated()),
                    id: \.offset) { _, entry in
                switch entry {
                case let .comment(c):
                    WorkCommentView(comment: c, compact: narrow) {
                        MarkdownText(markdown: ForgeMarkdown.markdown(c.body), remoteImage: image(on: host))
                    }
                case let .event(e):
                    if let words = WorkLook.eventWords(e) {
                        WorkTimelineEvent(symbol: WorkTimelineEvent.symbol(e, stateReason: got.item.stateReason), words: words, at: e.at)
                    }
                }
            }
            if got.item.node.kind == "issue", got.item.state == "closed", got.transitions == nil, !WorkLook.eventsSayClose(got.events) {
                WorkTimelineEvent(symbol: got.item.stateReason == "not_planned" ? "slash.circle" : "checkmark.circle",
                                  words: got.item.stateReason == "not_planned" ? "Closed as not planned" : "Closed",
                                  at: got.item.closedAt)
            }
            if got.item.node.kind == "pr" { pullEnd(got, on: host) }
        }
        if writes {
            WorkCommentBox(model: model, host: host, node: got.item.node,
                           // A standing epic never closes (epic.md note 16).
                           closes: got.transitions == nil && got.item.standing != true && ["open", "closed"].contains(got.item.state)
                               ? got.item.state : nil,
                           noun: isIssue ? "issue" : "pull request",
                           compact: narrow, said: said) { words, failed in
                said = (words, failed)
                if !failed { Task { await reread() } }
            }
        } else if !fromDevice, WorkLook.mergeBox(got) == nil {
            Text("No machine of yours can write to \(WorkList.forgeName(node.ref)).")
                .appText(.supporting).foregroundStyle(.secondary)
        }
    }

    /// The end of a pull request's timeline: the merge box while it is open (on a wide page; a
    /// narrow one has it at the top), *Merged* and the pipeline line once it merged, *Closed
    /// with unmerged commits* once it closed.
    @ViewBuilder
    private func pullEnd(_ got: DaemonAPI.ForgeItemDetail, on host: MachineRef) -> some View {
        switch got.item.state {
        case "merged":
            WorkTimelineEvent(symbol: "arrow.triangle.merge", words: "Merged", at: got.item.closedAt ?? got.item.updatedAt)
            mergedStrip
        case "closed":
            WorkTimelineEvent(symbol: "xmark.circle", words: "Closed with unmerged commits", at: got.item.closedAt ?? got.item.updatedAt)
        default:
            if !narrow, let box = WorkLook.mergeBox(got) { mergeBox(box, got, on: host) }
        }
    }

    private func mergeBox(_ box: WorkLook.MergeBox, _ got: DaemonAPI.ForgeItemDetail, on host: MachineRef) -> some View {
        WorkMergeBox(model: model, host: host, detail: got, box: box, writes: writes, waiting: fromDevice, compact: narrow) {
            Task { await reread() }
        }
    }

    /// In the merge box's place once it merged: *Merged.*, then (Mac) where it went (#3588).
    private var mergedStrip: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(WorkLook.mergedStrip).appText(.supporting).fontWeight(.semibold)
            #if os(macOS)
            if !pipeline.isEmpty { pipelineLine }
            #endif
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Paper.Radius.card).fill(Paper.well))
        .padding(.leading, narrow ? 0 : WorkTimelineEntry<EmptyView, EmptyView>.column + 10)
        .padding(.bottom, 14)
    }

    private var olderComments: some View {
        WorkTimelineEntry {
            Image(icon: "ellipsis").appText(.fine).foregroundStyle(.secondary)
                .frame(width: 22, height: 22).background(Circle().fill(Paper.well))
        } content: {
            Button(olderLoading ? "Loading…" : "Older comments") { Task { await readOlder() } }
                .linkStyle()
                .disabled(olderLoading)
                .padding(.top, 3)
        }
    }

    // MARK: Side panel

    private func sidePanel(compact: Bool, @ViewBuilder _ content: () -> some View) -> some View {
        WorkSidePanel(compact: compact) { content() }
            .redacted(reason: detail == nil ? .placeholder : [])
    }

    /// Assignees, Labels (its gear opens the labels picker), Repo and Project (parts.md section
    /// 5). The forge gives the author's picture (#4363): an assignee who wrote it has it.
    @ViewBuilder
    private var details: some View {
        let item = item
        WorkSideSection(title: "Assignees") {
            let assignees = item?.assignees ?? row?.assignees ?? []
            if assignees.isEmpty {
                WorkSideNone(words: "No one")
            } else {
                let author = item?.author ?? row?.author
                let avatar = item?.authorAvatar ?? row?.avatar
                ForEach(assignees, id: \.self) { WorkSidePerson(login: $0, avatar: $0 == author ? avatar : nil) }
            }
        }
        if node.kind == "pr" {
            // Each reviewer and their state come with the forge's reviewers (#4406, missing fields).
            WorkSideSection(title: "Reviewers") {
                let review = item?.review ?? row?.review
                if review == nil {
                    WorkSideNone(words: WorkLook.reviewersWords(nil))
                } else {
                    Text(WorkLook.reviewersWords(review))
                }
            }
        }
        WorkSideSection(title: "Labels", edit: labelsEdit) {
            let labels = item?.labels ?? row?.labels ?? []
            if labels.isEmpty {
                WorkSideNone(words: "None")
            } else {
                WrappingHStack(spacing: 4) {
                    ForEach(labels, id: \.name) { label in
                        WorkLabelChip(label: label, pick: pickLabel)
                    }
                }
            }
        }
        #if os(iOS)
        // A sheet on the Remote, the iPad too (#4401 note 12).
        .sheet(isPresented: $pickingLabels) { labelsPicker.paperSheet().presentationDetents([.medium, .large]) }
        #else
        .popover(isPresented: $pickingLabels, arrowEdge: .leading) { labelsPicker }
        #endif
        if node.kind == "pr", let files = WorkLook.branchWords(detail?.got.filesChanged) {
            // The head and base branches and the size come with the forge's fields (#4406).
            WorkSideSection(title: "Branch") {
                Label(files, icon: "arrow.triangle.branch").monospacedDigit()
            }
        }
        WorkSideSection(title: "Repo") {
            Text(WorkList.repoName(WorkList.repo(of: node.ref))).lineLimit(1).textSelection(.enabled)
        }
        if let projectName {
            WorkSideSection(title: "Project") { Text(projectName).lineLimit(1) }
        }
    }

    /// Linked, Lineage and (Mac) Docs: beside the page on a wide one, after the comment box on a narrow one.
    @ViewBuilder
    private var connections: some View {
        if let item {
            linked(item)
            lineageSection(item)
            #if os(macOS)
            // The docs it names and those like it (#3322): Mac + web, so not on the Remote (#2796).
            if item.node.kind == "issue" || item.node.kind == "pr" {
                WorkDocsSection(item: item, text: detail?.got.body ?? "", asked: asked)
            }
            #endif
        }
    }

    /// The parent, an epic's progress, then its children and the pull requests that close it,
    /// where the forge gives them (#4373); each opens its page.
    @ViewBuilder
    private func linked(_ item: DaemonAPI.ForgeItem) -> some View {
        let children = detail?.got.children ?? []
        let pulls = detail?.got.linkedPulls ?? []
        if item.parent != nil || item.progress != nil || !children.isEmpty || !pulls.isEmpty {
            WorkSideSection(title: "Linked") {
                if let parent = item.parent {
                    WorkSideLinked(node: parent) { show(parent) }
                }
                if let progress = item.progress {
                    ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                    Text("\(progress.done) of \(progress.total) closed").appText(.fine).foregroundStyle(.secondary).monospacedDigit()
                }
                ForEach(children + pulls, id: \.node.ref) { linked in
                    WorkSideLinked(node: linked.node, title: linked.title, state: linked.state) { show(linked.node) }
                }
            }
        }
    }

    private func show(_ node: DaemonAPI.LineageNode) {
        if let kind = WorkList.kind(of: node) { model.showWork(WorkPlace(kind: kind, ref: node.ref)) }
    }

    /// What lineage knows (#4400 note 14): the cost and the sessions, each a link with a green dot
    /// while it runs; then the estimate of an open issue, or what a closed one spent; on the Mac,
    /// the pipeline line (#3588).
    @ViewBuilder
    private func lineageSection(_ item: DaemonAPI.ForgeItem) -> some View {
        let sessions = lineage?.sessions ?? []
        let cost = lineage?.cost.flatMap { $0.total.cost.values.contains { $0 > 0 } ? ReportValueWords.cost($0.total) : nil }
        let forecastLines = forecastLines(item)
        let shows = !sessions.isEmpty || cost != nil || !forecastLines.isEmpty
            || estimate.map { item.state == "open" ? EstimateWords.shows($0) : EstimateWords.actualWords($0) != nil } == true
        #if os(macOS)
        let any = shows || !pipeline.isEmpty
        #else
        let any = shows
        #endif
        if any {
            WorkSideSection(title: "Lineage") {
                let counts = [cost, sessions.isEmpty ? nil : sessions.count == 1 ? "1 session" : "\(sessions.count) sessions"].compactMap { $0 }
                if !counts.isEmpty {
                    Text(counts.joined(separator: " · ")).monospacedDigit()
                }
                ForEach(sessions, id: \.self) { session(id: $0) }
                if let estimate, item.state == "open", EstimateWords.shows(estimate) {
                    estimateLine(estimate)
                } else if let estimate, item.state != "open", let words = EstimateWords.actualWords(estimate) {
                    Text(words).appText(.fine).foregroundStyle(.secondary).monospacedDigit()
                    #if os(macOS)
                        .textSelection(.enabled)
                    #endif
                }
                if !forecastLines.isEmpty { forecastLine(forecastLines, item: item) }
                #if os(macOS)
                if !pipeline.isEmpty { pipelineLine }
                #endif
            }
        }
    }

    /// A session this lineage names: a green dot while it runs, its title; it opens the chat.
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

    /// The gear on an issue's or a pull request's Labels, when a machine of the person's writes.
    private var labelsEdit: (() -> Void)? {
        guard [.issue, .pr].contains(place.kind), writes, let item, WorkList.takesLabels(item.node) else { return nil }
        return { pickingLabels = true }
    }

    @ViewBuilder
    private var labelsPicker: some View {
        if let detail {
            WorkLabelsPicker(model: model, host: detail.host, item: detail.got.item) { name, add in
                act(DaemonAPI.Method.forgeLabel,
                    DaemonAPI.ForgeLabelRequest(node: detail.got.item.node, add: add ? [name] : nil, remove: add ? nil : [name]))
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
        guard let item, item.node.kind == "issue" else { return nil }
        return LineageAsk(host: lineageHost, asked: asked)
    }

    /// An epic's forecast (#4527), from the machine that keeps its links: when an open one lands and
    /// what it costs to complete, and a closed one's first forecast against when it landed. A
    /// standing epic never lands (#3662).
    private var forecastAsk: LineageAsk? {
        guard let item, item.node.kind == "issue", isEpic, item.standing != true else { return nil }
        return LineageAsk(host: lineageHost, asked: asked)
    }

    /// The cost and the sessions of an issue or a pull request, from the machine that keeps its links.
    private var lineageAsk: LineageAsk? {
        guard detail != nil, [.issue, .pr].contains(place.kind), !node.ref.isEmpty else { return nil }
        return LineageAsk(host: lineageHost, asked: asked)
    }

    /// The outer loop in reach of an issue, a PR or a release (#3588), from the machine that keeps
    /// its links: Mac + web, so not on the Remote (#2796).
    private var pipelineAsk: LineageAsk? {
        guard [.issue, .pr, .release].contains(place.kind), !node.ref.isEmpty else { return nil }
        return LineageAsk(host: lineageHost, asked: asked)
    }

    /// "Estimate: about $3.20, 45K output tokens, 2h 10m of work (from 31 closed stories)", and for
    /// an epic what its closed children spent. The range is its help on the Mac; on the Remote a
    /// tap shows it under the line.
    @ViewBuilder
    private func estimateLine(_ e: DaemonAPI.LineageEstimate) -> some View {
        let range = EstimateWords.rangeWords(e)
        let line = Text(([EstimateWords.line(e)] + [EstimateWords.spentWords(e)].compactMap { $0 }).joined(separator: " · "))
            .appText(.fine).foregroundStyle(.secondary).monospacedDigit()
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

    /// An open epic's "Likely lands by …" and "To complete: …", or a closed one's first forecast
    /// against when it landed (#4527).
    private func forecastLines(_ item: DaemonAPI.ForgeItem) -> [String] {
        guard let forecast, forecastAsk != nil else { return [] }
        if item.state == "open" {
            return [ForecastWords.landsLine(forecast), ForecastWords.toCompleteLine(forecast)].compactMap { $0 }
        }
        return [ForecastWords.keptLine(forecast, landed: item.closedAt)].compactMap { $0 }
    }

    /// The forecast's lines under the estimate. The assumptions are their help on the Mac; on the
    /// Remote a tap shows them under the lines, as the estimate's range does.
    @ViewBuilder
    private func forecastLine(_ lines: [String], item: DaemonAPI.ForgeItem) -> some View {
        let help = forecast.flatMap { item.state == "open" ? ForecastWords.help($0) : ForecastWords.keptHelp($0) }
        let text = Text(lines.joined(separator: "\n"))
            .appText(.fine).foregroundStyle(.secondary).monospacedDigit()
            .accessibilityHint(help ?? "")
        #if os(iOS)
        text.onTapGesture { if help != nil { forecastHelp.toggle() } }
        if forecastHelp, let help {
            Text(help).appText(.fine).foregroundStyle(.secondary).monospacedDigit()
        }
        #else
        text.textSelection(.enabled).help(help ?? "")
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
        return Text(line).appText(.fine).foregroundStyle(.secondary).monospacedDigit()
    }

    // MARK: Writing

    /// A write from the header or the side panel (the status menu, a label), to the machine that
    /// read it; what it did is the line under the comment box's buttons.
    private func act(_ method: String, _ params: some Encodable & Sendable) {
        guard let host = detail?.host, !writing else { return }
        Task {
            writing = true
            defer { writing = false }
            do {
                let done = try await model.forge(method, params, returning: DaemonAPI.ForgeDone.self, on: host)
                let close = params as? DaemonAPI.ForgeCloseRequest
                said = (WorkList.doneWords(method, done, reopened: close?.reopen == true, moved: close?.transition != nil), false)
                await reread()
            } catch {
                said = (WorkList.failureWords(error), true)
            }
        }
    }

    /// An image in the body or a comment, read by the machine that read the item (#4010,
    /// `forge/image`), so the app never loads the page's remote URL. Nil when it cannot.
    private func image(on host: MachineRef) -> RemoteImageLoader {
        { [model] url in
            guard let data = await model.forgeImage(url.absoluteString, on: host) else { return nil }
            return PlatformImage(data: data)
        }
    }

    // MARK: Loading

    /// An item as this device keeps it (#4930): the machine that read it, its body and its newest page of comments.
    struct KeptItem: Codable, Sendable {
        var host: MachineRef
        var got: DaemonAPI.ForgeItemDetail
    }

    /// The item, from the first machine that reads it. A refresh keeps the page as it is, and
    /// the toolbar's Refresh spins, until the new read comes.
    private func loadForge() async {
        let mine = asked
        guard place.kind.fromForge else { return }
        let machines = model.forgeMachines
        guard !machines.isEmpty else { forgeProblem = WorkList.noForgeHere; return }
        reading = true
        defer { if asked == mine { reading = false } }
        // Seen before: this device's copy at once, until a machine answers (#4930).
        if detail == nil, let kept = await model.keptWork(KeptItem.self, .item, node.ref), asked == mine, detail == nil {
            detail = (kept.host, kept.got)
            fromDevice = true
        }
        var last: String?
        for machine in machines {
            do {
                let got = try await model.forgeItem(node, cursor: nil, on: machine.id)
                guard asked == mine else { return }
                detail = (machine.id, got)
                fromDevice = false
                forgeProblem = nil
                model.keepWork(KeptItem(host: machine.id, got: got), .item, node.ref)
                return
            } catch {
                last = WorkList.failureWords(error)
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
            fromDevice = false
            model.keepWork(KeptItem(host: had.host, got: got), .item, node.ref)
        } catch {
            forgeProblem = error.localizedDescription
        }
    }

    private func readOlder() async {
        guard !fromDevice, let had = detail, let cursor = had.got.cursor else { return }
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

    private func loadLineage() async {
        let mine = lineageAsk
        guard let mine, let host = mine.host else { lineage = nil; return }
        async let cost = model.lineageCost(node, on: host)
        async let walk = try? model.lineageWalk(node, depth: LineageList.depth, on: host)
        let (rollup, graph) = await (cost, walk)
        guard lineageAsk == mine else { return }
        lineage = (rollup, WorkPlan.sessions(node, links: graph?.links ?? [], rollup: rollup))
    }

    private func loadEstimate() async {
        let mine = estimateAsk
        estimate = nil
        guard let mine, let host = mine.host else { return }
        let got = await model.lineageEstimate(node, on: host)
        guard estimateAsk == mine else { return }
        estimate = got
    }

    private func loadForecast() async {
        let mine = forecastAsk
        forecast = nil
        guard let mine, let host = mine.host else { return }
        let got = await model.lineageForecast(node, on: host)
        guard forecastAsk == mine else { return }
        forecast = got
    }
}

/// The page header's state pill (#4400 note 6, parts.md section 1): the state's glyph and word,
/// *Open*, *Closed*, *Merged*, *Draft*, on the state's colour. A tracker's status (a Jira status,
/// #3260) with no write is its word in today's pill.
struct WorkPagePill: View {
    let kind: String
    let state: String
    var draft = false
    var status: String?
    /// The forge's `not_planned` (#4365): the grey pill with a slash.
    var stateReason: String?

    var body: some View {
        if let glyph = WorkLook.glyph(kind: kind, state: state, draft: draft, stateReason: stateReason), status == nil {
            HStack(spacing: 4) {
                WorkStateIcon(kind: kind, state: state, draft: draft, stateReason: stateReason, onFill: true)
                Text(words)
            }
            .appText(.supporting)
            .fontWeight(.medium)
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(glyph.tone.color))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(glyph.accessibilityLabel)
        } else {
            WorkStatePill(state: state, draft: draft, status: status)
        }
    }

    private var words: String {
        if draft, state == "open" { return "Draft" }
        return state.prefix(1).uppercased() + state.dropFirst()
    }
}
