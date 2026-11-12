import AgentsKitCore
import SwiftUI

/// One of the groups at the top of the sidebar (#495): Pinned, Needs You, For Review
/// (#3194), Working or Unread, across every folder and host. Needs You lists, after its
/// sessions, everything else waiting for an OK (#773). A section headed and folding as a
/// folder's is, so its heading and rows line up with theirs. Folded, it reads its count off each
/// folder's shelf and lists nothing (#356). Empty, it is not drawn (#507).
struct SmartFold: View {
    @Environment(AppModel.self) private var model
    let row: SidebarSmartRow
    /// The folders in the sidebar, in its order.
    let folders: [FolderKey]
    let folds: SidebarFolds
    /// The search's words, already trimmed; empty when there is no search.
    let query: String
    /// Each folder's group name (#3278): its project's, when it shares one with other folders.
    var places: [FolderKey: String] = [:]
    /// The smart groups turned off in Settings ▸ Sidebar (#846): their sessions are listed
    /// by the next group they fit.
    @AppStorage(SidebarSmartRow.offDefaultsKey, store: WindowDefaults.store) private var smartOff = SidebarSmartRow.offAtFirst
    private var on: Set<SidebarSmartRow> { SidebarSmartRow.on(off: smartOff) }

    var body: some View {
        // Unread with nothing unread is still drawn while it keeps the open session.
        if row.isShown(in: model.work, folders: folders, query: query, on: on) || keptUnread != nil {
            fold
        }
    }

    private var fold: some View {
        let isOpen = folds.isOpen(row)
        let open = Binding(get: { isOpen }, set: { folds.set(row, open: $0) })
        let agents = isOpen ? shown : []
        return Section(isExpanded: open) {
            if row == .pinned {
                if isOpen { pinnedRows }
            } else {
                if isOpen {
                    ForEach(row.requests(in: model.work, folders: folders, query: query), id: \.request.id) { item in
                        RequestListRow(request: item.request, place: place(of: item.folder))
                    }
                }
                // Each under the session that started it when this group lists that too (#835).
                ForEach(FoldedRow.rows(SidebarTree.rows(agents, in: model.work, folds: folds), in: .smart(row))) { item in
                    SessionSidebarRow(agent: item.item.agent, place: place(of: item.item.agent),
                                      tree: item.item, folds: folds)
                }
                if isOpen {
                    ForEach(row.approvals(in: model.work, folders: folders, query: query), id: \.approval.id) { item in
                        if item.approval.opensItsSubject {
                            FailedWorkflowRow(approval: item.approval, folder: item.folder,
                                              place: place(of: item.folder))
                        } else {
                            ApprovalListRow(approval: item.approval, folder: item.folder,
                                            place: place(of: item.folder))
                        }
                    }
                    ForEach(row.pulls(in: model.work, folders: folders, query: query), id: \.pull.id) { item in
                        ReviewPullListRow(pull: item.pull, folder: item.folder, place: place(of: item.folder))
                    }
                    ForEach(row.suggestions(in: model.work, folders: folders, query: query),
                            id: \.suggestion.id) { item in
                        CheckSuggestionListRow(suggestion: item.suggestion, folder: item.folder,
                                               place: place(of: item.folder))
                    }
                    LaterRows(requests: row.laterRequests(in: model.work, folders: folders, query: query)) {
                        place(of: $0)
                    }
                }
            }
        } header: {
            heading(open)
        }
    }

    /// The group's heading. No Approve All (#704): each is approved from its own row.
    private func heading(_ open: Binding<Bool>) -> some View {
        SmartRowLabel(row: row, count: row.count(in: model.work, folders: folders, on: on)) {
            open.wrappedValue.toggle()
        }
    }

    /// What the row lists. Unread keeps the session opened from it (`keptInUnread`) in
    /// its place, read now, until another is opened: its count has already dropped.
    private var shown: [Agent] {
        var agents = row.agents(in: model.work, folders: folders, query: query, on: on)
        if let kept = keptUnread, !agents.contains(where: { $0.id == kept.id }) {
            let at = agents.firstIndex { $0.createdAt < kept.createdAt } ?? agents.endIndex
            agents.insert(kept, at: at)
        }
        return agents
    }

    /// The session Unread keeps, read, while it is the one open, or For Review when it had a
    /// file to see (#3194); none while searching.
    private var keptUnread: Agent? {
        row == SidebarSmartRow.keeper(fileToSee: model.keptHadFile, on: on)
            ? SidebarSmartRow.keptInUnread(model.keptInUnread, in: model.work, query: query, on: on, keptBy: row) : nil
    }

    /// Every folder's pinned sessions, then its pinned workflows, each dragged into the
    /// order wanted among its own folder's and its own kind (#180, #432).
    @ViewBuilder
    private var pinnedRows: some View {
        let searching = !query.isEmpty
        ForEach(folders, id: \.self) { key in
            let sessions = SidebarSmartRow.pinned.agents(in: model.work, folders: [key], query: query)
            ForEach(FoldedRow.rows(sessions, in: .smart(.pinned))) { item in
                SessionSidebarRow(agent: item.item, place: place(of: item.item))
            }
            // The whole order, which a search shows only some of.
            .onMove { from, to in
                guard !searching else { return }
                var ids = sessions.map(\.id)
                ids.move(fromOffsets: from, toOffset: to)
                let shown = Set(ids)
                let rest = model.pinnedSessions(in: key.folder).filter { !shown.contains($0) }
                Task { await model.arrangeSessionPins(ids + rest, in: key) }
            }
            let flows = SidebarSmartRow.pinned.workflows(in: model.work, folders: [key], query: query).map(\.workflow)
            ForEach(FoldedRow.rows(flows, in: .smart(.pinned))) { item in
                WorkflowListRow(summary: item.item, folder: key)
            }
            .onMove { from, to in
                guard !searching else { return }
                var ids = flows.map(\.workflowID)
                ids.move(fromOffsets: from, toOffset: to)
                let shown = Set(ids)
                let rest = model.pinnedWorkflows(in: key.folder).filter { !shown.contains($0) }
                Task { await model.arrangeWorkflowPins(ids + rest, in: key) }
            }
        }
    }

    /// The folder's name as its row in the sidebar says it: `server:Folder` on a server.
    private func place(of agent: Agent) -> String? {
        place(of: FolderKey(host: agent.host, folder: agent.folderPath))
    }

    private func place(of key: FolderKey) -> String? {
        if let place = places[key] { return place }
        guard let summary = model.work.folder(key) else { return nil }
        return SidebarOrder.label(summary) { model.hosts.label($0) }
    }
}

/// One request to the person under Needs You (#3864): a click opens the session that asked
/// it, where its card takes the answer. A secret's use (#4017) has no card: its menu has Allow
/// Once, Approve for This Session, Always Approve and Deny, Approve is a leading swipe and Deny a
/// trailing one, as an approval's row has (#3763). A terminal's agents-secret (#4179) has no
/// session to open: its menu has Approve, Approve for 1 Hour and Deny, and its grey line says
/// that Agents cannot tell a terminal from an agent outside its session.
private struct RequestListRow: View {
    @Environment(AppModel.self) private var model
    /// In a folder's own window, how it opens what is picked (#1090).
    @Environment(\.windowOpen) private var windowOpen
    let request: NeedRequest
    let place: String?

    var body: some View {
        if let id = request.askedBy {
            let item = SidebarItem.session(id)
            RequestRowLabel(request: request, asker: model.work.agent(id)?.title, place: place)
                .help(request.line(asker: model.work.agent(id)?.title))
                .sidebarInk(item)
                .tag(item)
                .modifier(SecretUseAnswers(request: request))
                .contextMenu {
                    SecretUseMenu(request: request)
                    if request.secretUse != nil { Divider() }
                    Button("Open Session") {
                        if let windowOpen { windowOpen(item) } else { model.sidebarItem = item }
                    }
                    Divider()
                    RequestLaterMenu(request: request)
                }
        } else if request.isTerminal {
            RequestRowLabel(request: request, place: place)
                .help(request.line(asker: nil))
                .modifier(SecretUseAnswers(request: request))
                .contextMenu {
                    SecretUseMenu(request: request)
                    Divider()
                    RequestLaterMenu(request: request)
                }
        }
    }
}

/// Needs You's folded Later group (#4234), at its end: its heading folds it, and says how
/// many; its rows are the deferred requests, each saying when it comes back. In no count.
private struct LaterRows: View {
    let requests: [(folder: FolderKey, request: NeedRequest)]
    let place: (FolderKey) -> String?
    /// Folded at first, and kept as it was left, in this copy's own defaults.
    @AppStorage("sidebar.needsYou.laterOpen", store: WindowDefaults.store) private var open = false

    var body: some View {
        if !requests.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .imageScale(.small)
                    .rotationEffect(.degrees(open ? 90 : 0))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text("Later")
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
                Text("\(requests.count)")
                    .monospacedDigit()
                    .appText(.fine)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
            }
            .appText(.supporting)
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(ResponseMotion.snappy) { open.toggle() } }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Later, \(requests.count)")
            .accessibilityValue(open ? "unfolded" : "folded")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { open.toggle() }
            if open {
                ForEach(requests, id: \.request.id) { item in
                    RequestListRow(request: item.request, place: place(item.folder))
                }
            }
        }
    }
}

/// A secret's use's swipes: Approve leading, Deny trailing.
private struct SecretUseAnswers: ViewModifier {
    @Environment(AppModel.self) private var model
    let request: NeedRequest

    func body(content: Content) -> some View {
        content
            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                if request.secretUse != nil {
                    SwipeAction { await model.answerSecretUse(request, .once) } label: {
                        Label(NeedRequest.Action.once.word, systemImage: "checkmark")
                    }
                    .tint(Paper.accent)
                }
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                if request.secretUse != nil {
                    SwipeAction { await model.answerSecretUse(request, .deny) } label: {
                        Label(NeedRequest.Action.deny.word, systemImage: "xmark")
                    }
                    .tint(StateTint.failure.color)
                }
            }
    }
}

/// A secret's use's answers, in its menu.
private struct SecretUseMenu: View {
    @Environment(AppModel.self) private var model
    let request: NeedRequest

    var body: some View {
        if let use = request.secretUse {
            ForEach(use.actions, id: \.self) { action in
                Button(action.word, role: action == .deny ? .destructive : nil) {
                    Task { await model.answerSecretUse(request, action) }
                }
            }
        }
    }
}

/// One thing waiting for an OK under Needs You (#773): an MCP server, a workflow, a plugin
/// or a guarded file. A click opens its Review page in the detail column (#1472), with
/// Approve, Deny and, where an agent made it, Request Changes; the menu answers at once, and
/// so do Approve, a leading swipe, and Deny, a trailing one (#3763).
private struct ApprovalListRow: View {
    @Environment(AppModel.self) private var model
    /// In a folder's own window, how it opens what is picked (#1090).
    @Environment(\.windowOpen) private var windowOpen
    let approval: Approval
    let folder: FolderKey
    let place: String?

    private var item: SidebarItem { .review(approval.id, in: folder) }

    var body: some View {
        ApprovalRowLabel(approval: approval, place: place)
            .help("\(approval.kindWord) · \(approval.line)")
            .sidebarInk(item)
            .tag(item)
            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                if approval.actions.contains(.approve) {
                    SwipeAction { await answer(.approve) } label: {
                        Label(approval.word(for: .approve), systemImage: "checkmark")
                    }
                    .tint(Paper.accent)
                }
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                if approval.actions.contains(.deny) {
                    SwipeAction { await answer(.deny) } label: {
                        Label(approval.word(for: .deny), systemImage: "xmark")
                    }
                    .tint(StateTint.failure.color)
                }
            }
            .contextMenu {
                Button("Review…") { open() }
                if approval.actions.contains(.approve) {
                    Button(approval.word(for: .approve)) { answerNow(.approve) }
                }
                if approval.actions.contains(.deny) {
                    Button(approval.word(for: .deny)) { answerNow(.deny) }
                }
                if approval.actions.contains(.requestChanges) {
                    Button(approval.word(for: .requestChanges) + "…") { open() }
                }
            }
    }

    private func open() {
        if let windowOpen { windowOpen(item) } else { model.sidebarItem = item }
    }

    /// From the menu or a swipe, of the version the row was drawn from: a later change is
    /// refused.
    private func answerNow(_ action: Approval.Action) {
        Task { await answer(action) }
    }

    private func answer(_ action: Approval.Action) async {
        await model.settleApproval(approval, action, for: folder)
    }
}

/// A pull request waiting for the person's approval, under For Review (#3330). A click opens
/// its Work page, with its screenshots in its body, or its forge page in the browser when the
/// host said no ref; Dismiss, a trailing swipe as Archive is on a
/// session's row, and in its menu, takes it out for good.
private struct ReviewPullListRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    let pull: ReviewPull
    let folder: FolderKey
    let place: String?

    var body: some View {
        ReviewPullRowLabel(pull: pull, place: place)
            .help("\(pull.title) · Pull request #\(pull.number) · \(pull.repo)")
            .pointerStyle(.link)
            .onTapGesture(perform: open)
            .swipeActions(edge: .trailing) {
                SwipeAction("Dismiss", systemImage: "xmark") { await dismissNow() }
                    .tint(.gray)
            }
            .contextMenu {
                Button("Open Pull Request", action: open)
                Button("Dismiss", action: dismiss)
            }
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(named: "Dismiss", dismiss)
    }

    private func dismiss() {
        Task { await dismissNow() }
    }

    private func dismissNow() async {
        await model.dismissReview(pull, in: folder)
    }

    /// Opens its Work page, else its forge page, and draws it read from then on (#3464).
    private func open() {
        if let ref = pull.ref { model.showWork(WorkPlace(kind: .pr, ref: ref)) } else { openURL(pull.url) }
        Task { await model.openReview(pull, in: folder) }
    }
}

/// A suggestion of the read-only daily checks, under For Review (#3331). A click, or Start as a
/// leading swipe, starts a session in its folder with its prompt and opens it; Dismiss, a
/// trailing swipe, and in its menu, takes it out for good, as the Remote's row has them.
private struct CheckSuggestionListRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    let suggestion: CheckSuggestion
    let folder: FolderKey
    let place: String?

    var body: some View {
        CheckSuggestionRowLabel(suggestion: suggestion, place: place)
            .help("\(suggestion.title) · \(CheckSuggestionRowLabel.line(suggestion))")
            .onTapGesture(perform: start)
            .swipeActions(edge: .leading) {
                SwipeAction("Start", systemImage: "play") {
                    await model.startSuggestion(suggestion, in: folder)
                }
                .tint(Paper.accent)
            }
            .swipeActions(edge: .trailing) {
                SwipeAction("Dismiss", systemImage: "xmark") {
                    await model.dismissSuggestion(suggestion, in: folder)
                }
                .tint(.gray)
            }
            .contextMenu {
                Button("Start Session", action: start)
                if let link = suggestion.link {
                    Button("Open Link") { openURL(link) }
                }
                Button("Dismiss", action: dismiss)
            }
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(named: "Start", start)
            .accessibilityAction(named: "Dismiss", dismiss)
    }

    private func start() {
        Task { await model.startSuggestion(suggestion, in: folder) }
    }

    private func dismiss() {
        Task { await model.dismissSuggestion(suggestion, in: folder) }
    }
}

/// A workflow that has stopped working, under Needs You (#989): the failure in its grey line.
/// Picking it opens the run's agent, which Needs You does not list again, or the workflow
/// when no agent ran; Dismiss, in its menu, takes it out until it fails again.
private struct FailedWorkflowRow: View {
    @Environment(AppModel.self) private var model
    /// In a folder's own window, how it opens what is picked (#1090).
    @Environment(\.windowOpen) private var windowOpen

    /// In this window: a folder's own, or the main window's selection.
    private func open(_ item: SidebarItem) {
        if let windowOpen { windowOpen(item) } else { model.sidebarItem = item }
    }
    let approval: Approval
    let folder: FolderKey
    let place: String?

    var body: some View {
        ApprovalRowLabel(approval: approval, place: place)
            .help("\(approval.kindWord) · \(approval.line)")
            .sidebarInk(item)
            .tag(item)
            .contextMenu {
                Button("Open") { open(item) }
                if approval.agentID != nil {
                    Button("Open Workflow") { open(workflow) }
                }
                if approval.actions.contains(.dismiss) {
                    Button(approval.word(for: .dismiss)) {
                        Task { await model.settleApproval(approval, .dismiss, for: folder) }
                    }
                }
            }
    }

    private var item: SidebarItem { approval.agentID.map(SidebarItem.session) ?? workflow }

    private var workflow: SidebarItem {
        let id = model.work.workflows(in: folder.folder).first { $0.workflowID == approval.key }?.id
            ?? folder.folder.path + "/" + approval.key
        return .workflow(id, in: folder)
    }
}

/// A smart row's own line: its symbol, its name, and how many, the count in the
/// attention tint when somebody is waiting; absent at none, which only Unread keeping
/// the open session is drawn at.
private struct SmartRowLabel: View {
    let row: SidebarSmartRow
    let count: Int
    /// A click on the heading folds or unfolds it, as on a folder's (#375).
    var onClick: () -> Void = {}

    var body: some View {
        // No icon (Alex, #495): the sessions under it carry the marks. Grey, as every
        // group's heading is.
        HStack(spacing: 6) {
            Text(row.title)
                .lineLimit(1)
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            if count > 0 {
                Text("\(count)")
                    .monospacedDigit()
                    .appText(.fine)
                    .foregroundStyle(row == .needsYou ? StateTint.attention.style(or: .secondary)
                                                      : AnyShapeStyle(.secondary))
            }
        }
        // A heading runs to the list's edge, its rows stop short of it: this keeps the
        // count over the rows' counts and times (#495).
        .padding(.trailing, SidebarHeading.trailingInset)
        .appText(.supporting)
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded { onClick() })
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(count > 0 ? "\(row.title), \(count)" : "\(row.title), none")
    }
}

/// How far in from the list's edge a group heading's trailing mark sits, so it lines up
/// with the trailing counts and times of the rows under it (#495).
enum SidebarHeading {
    static let trailingInset: CGFloat = 11
}

/// A row under a folder that opens a page about it (#495): its workflows, or its
/// archive. One row each where they used to be folds inside the folder's fold.
struct FolderPageRow: View {
    let title: String
    let systemImage: String
    let item: SidebarItem
    /// Red when the page has something wrong to say, as an Activity row's (#753).
    var warns = false
    /// How many the page holds, small and grey after the title (#1569); none at zero.
    var count: Int?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .sidebarMark(warns ? StateTint.failure.style(or: .primary) : AnyShapeStyle(Paper.accent))
                .frame(width: 16)
                .accessibilityHidden(true)
            // White, as every row's title is (#587); nothing at its end, which is only
            // a session's. The Connectors row has its count after the title, as a
            // subheading does (#1569), because Alex asked to see it there.
            Text(title)
                .lineLimit(1)
                .foregroundStyle(.primary)
            if let count, count > 0 {
                Text("\(count)")
                    .monospacedDigit()
                    .appText(.fine)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            Spacer(minLength: 4)
        }
        // The size of the rows around it, sessions and New Session alike.
        .appText(.supporting)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .sidebarInk(item)
        .tag(item)
    }
}

/// A page about all the work in the sidebar's Activity group (#495): its icon, in the
/// accent, before the row. Beside the row rather than a `Label`, whose title a sidebar
/// list draws in its own style (#155).
private struct ActivityIcon: ViewModifier {
    let systemImage: String
    /// Red when the page has something wrong to say (#587): the row has no figure at its
    /// end to colour, which is only a session's.
    var warns = false
    /// The warning's tint: the attention orange for a page that only warns (#4161).
    var tint: StateTint = .failure

    func body(content: Content) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .sidebarMark(warns ? tint.style(or: .primary) : AnyShapeStyle(Paper.accent))
                .frame(width: 16)
                .accessibilityHidden(true)
            content
        }
    }
}

extension View {
    func activityIcon(_ systemImage: String, warns: Bool = false, tint: StateTint = .failure) -> some View {
        modifier(ActivityIcon(systemImage: systemImage, warns: warns, tint: tint))
    }
}
