import AgentsKitCore
import SwiftUI

/// One session under its folder: the Mac's compact `AgentRow`, tagged into the sidebar's
/// one selection (#226). A swipe from the leading edge pins it, from the trailing edge
/// archives it or brings it back, and a long press is the Mac's row menu.
struct SidebarSessionRow: View {
    @Environment(RemoteModel.self) private var model
    /// The agent as the list had it when it drew this row. Only its id is trusted.
    private let given: Agent
    /// Which folder it is in, after the title: under a smart group of the sidebar
    /// (#495, #498), which gathers sessions from every folder, and nowhere else.
    private let place: String?
    /// Where it sits in its list's tree (#835): a parent with its count and fold, or a
    /// child one indent in, as on the Mac.
    private let tree: SidebarTree.Row?
    private let folds: SidebarFolds?
    /// In its folder's Sessions fold: one level in, under the word Sessions (#2312).
    private let isNested: Bool
    /// The mark's well and the gap after it, as the Workflows fold's rows have them (#750).
    @ScaledMetric private var scale: CGFloat = 1

    init(agent: Agent, place: String? = nil, tree: SidebarTree.Row? = nil, folds: SidebarFolds? = nil,
         isNested: Bool = false) {
        given = agent
        self.place = place
        self.tree = tree
        self.folds = folds
        self.isNested = isNested
    }

    /// The session whose mark the row shows: its own, or for a folded parent the most
    /// urgent of it and the sessions it started (#835).
    private var markAgent: Agent {
        guard let tree, tree.children > 0, !tree.isUnfolded else { return agent }
        return SidebarTree.markAgent(of: agent, in: model.work)
    }

    private func toggleFold() {
        guard let tree else { return }
        folds?.set(session: agent.id, open: !tree.isUnfolded)
    }

    /// The agent as the phone has it now, read from the model rather than kept: see the
    /// Mac's `AgentRow`.
    private var agent: Agent { model.work.agent(given.id) ?? given }

    private var startedByWorkflowName: String? {
        guard let id = agent.startedByWorkflow else { return nil }
        return model.work.workflows(in: agent.folderPath)
            .first { $0.workflow.workflowID == id }?.workflow.name ?? id
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // What it wants, as the window's sidebar says it (#495): the state is the
            // row's mark; unread is the bold title (#1323). Archived keeps its icon.
            if agent.state == .archived {
                Image(systemName: "archivebox")
                    .glyph(size: 13)
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .accessibilityLabel("Archived")
            } else if let mark = SessionMark(agent: markAgent, group: model.work.group(of: markAgent)) {
                mark
            } else {
                StatusIcon(state: agent.state, isComingBack: model.isComingBack(agent),
                           outcome: agent.report?.outcome,
                           isWaiting: agent.isWaiting,
                           endedReason: agent.endedReason,
                           outcomeUnknown: agent.endingIsUnaccountedFor,
                           tool: RunningToolWords.tool(agent))
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    // The folder's name whole up to 40% of the line, then cut (#936), as on the Mac.
                    TitleAndPlace {
                        Text(agent.title ?? "Untitled")
                            .appText(.supporting)
                            .fontWeight(agent.drawsUnread ? .semibold : .regular)
                            .lineLimit(1)
                        if let place {
                            Text(place)
                                .appText(.fine)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }
                    // Started by a workflow (the Mac row's mark), then by another agent.
                    if let workflowName = startedByWorkflowName {
                        Image(systemName: "flowchart")
                            .appText(.fine)
                            .foregroundStyle(.tertiary)
                            .accessibilityLabel("started by the workflow \(workflowName)")
                    }
                    if let starter = model.startedByAgentLabel(agent) {
                        Image(systemName: AgentsModel.startedByAgentSymbol)
                            .appText(.fine)
                            .foregroundStyle(.tertiary)
                            // Said, as the workflow mark is and the Mac's row says it (#1326).
                            .accessibilityLabel(starter)
                    }
                    // Mute Notifications (#2003), as on the Mac.
                    if agent.isMuted {
                        Image(systemName: MuteWords.symbol)
                            .appText(.fine)
                            .foregroundStyle(.tertiary)
                            .accessibilityLabel(MuteWords.muted)
                    }
                    // Voice mode listens in this chat (#2518), beside the mute mark.
                    if VoiceMode.shared.isOn(in: agent.id) {
                        ListeningMark()
                    }
                    // A file it showed that the person has not looked at (#1802), as on the Mac.
                    if let file = FileToSeeWords.line(agent) {
                        Image(systemName: FileToSeeWords.symbol)
                            .appText(.fine)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel(file)
                    }
                }
                // The agent's own account of its last turn, one line, as on the Mac.
                if let acting = model.acting(agent.id) {
                    Telling(host: model.answerRecipient(agent.id), doing: acting.doing)
                } else if let queued = model.queuedLine(agent) {
                    // Its place in its folder's queue (#362), as the Mac's row says it.
                    Text(queued)
                        .appText(.fine)
                        .foregroundStyle(.secondary)
                } else if let reason = needsYouLine {
                    Text(reason)
                        .appText(.fine)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if agent.missingFolder != nil, agent.state != .archived {
                    Text(MissingFolderWords.label)
                        .appText(.fine)
                        .foregroundStyle(.secondary)
                } else if let said = model.work.saidLines[agent.id] {
                    // While the sidebar searches: the line it said that matches, in the
                    // report's place, so a row found by what it said says why (#1663).
                    Text(said)
                        .appText(.fine)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if let report = FileToSeeWords.reportLine(agent) {
                    // A file to see is named here first, as on the Mac (#1873).
                    Text(report)
                        .appText(.fine)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                // The row is the title and that one line (#587): what it holds, waits on,
                // runs or is labelled with is the chat's to say, and Carry on is in the
                // row's long press.
            }
            Spacer(minLength: 0)
            // How many it started, and their fold (#835), as on the Mac.
            if let tree, tree.children > 0 {
                Button(action: toggleFold) {
                    HStack(spacing: 3) {
                        Text("\(tree.children)")
                        Image(systemName: "chevron.right")
                            .rotationEffect(.degrees(tree.isUnfolded ? 90 : 0))
                    }
                    .appText(.fine)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .frame(minHeight: 28)
                    .contentShape(Rectangle())
                }
                // Only the count folds; the rest of the row opens the chat.
                .buttonStyle(.borderless)
            }
            // When it last did anything, as the page's row has it (#341).
            ActivityTime(date: agent.lastActivityAt)
        }
        // A child one indent in, under the mark's column (#835); in a Sessions fold, one
        // more (#2312).
        .padding(.leading, (tree?.isChild == true ? 26 : 0) + (isNested ? 20 * scale + 10 : 0))
        // Last known, not current: its host is not answering.
        .opacity(model.isStale(agent) ? 0.55 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityValue(agent.drawsUnread ? "unread" : "")
        .modifier(FoldAction(tree: tree, toggle: toggleFold))
        .tag(SidebarItem.session(agent.id))
        .contextMenu { AgentMenuItems(agent: agent) }
        // Out of the sidebar into a scene of its own, on an iPad (#888).
        .draggableToNewWindow(agent)
        // Pin or Unpin (#180), from the leading edge, as on the Mac.
        .swipeActions(edge: .leading) {
            if agent.state != .archived {
                PinAgentButton(agent: agent).tint(Paper.accent)
            }
        }
        // Archive or Unarchive, and Mark as Read or Unread, from the trailing edge. A long
        // swipe archives, as in Mail.
        .swipeActions(edge: .trailing, allowsFullSwipe: agent.state != .archived) {
            if agent.state == .archived {
                UnarchiveAgentButton(agent: agent)
            } else {
                ArchiveAgentButton(agent: agent).tint(.gray)
                if agent.state == .finished {
                    MarkReadButton(agent: agent).tint(Paper.accent)
                }
            }
        }
    }

    /// What the session asked, or why it stopped, while this row needs a person.
    private var needsYouLine: String? {
        let question = model.work.permission(for: agent.id)?.toolCall.line
            ?? model.work.elicitation(for: agent.id)?.message
            ?? model.work.elicitation(for: agent.id)?.title
        return StatusShape.needsYouLine(row: agent, isComingBack: model.isComingBack(agent), question: question)
    }
}

/// A parent's fold as an action of the row, which reads as one element (#835).
private struct FoldAction: ViewModifier {
    let tree: SidebarTree.Row?
    let toggle: () -> Void

    func body(content: Content) -> some View {
        if let tree, tree.children > 0 {
            content.accessibilityAction(named: tree.isUnfolded ? "Hide started sessions"
                                                               : "Show \(tree.children) started sessions", toggle)
        } else {
            content
        }
    }
}

/// A session's mark in the sidebar (#495, #498), the window's: what it wants, in four
/// shapes — an orange hand when it needs the person, a spinner in the accent while it
/// works (#1558), a tick once done, read or not (#1323, #2363); a numbered list while queued, a
/// breathing beacon while it waits (#2456, #2657) and a pause mark once stopped (#630).
/// An orange archive box when it asks to be archived, as it is listed under Needs You
/// (#817). Archived keeps its `StatusIcon`.
private struct SessionMark: View {
    private enum Kind { case needsYou, working, queued, waiting, paused, done, asksToArchive }
    private let kind: Kind
    private let agent: Agent
    /// The tool a working session runs (#1902): a wrench in the spinner's place.
    private var tool: String?

    init?(agent: Agent, group: AgentGroup) {
        self.agent = agent
        tool = group == .running ? RunningToolWords.tool(agent) : nil
        switch group {
        case .needsAttention, .blocked: kind = .needsYou
        case .running: kind = .working
        // Asking to be archived (#584), as the window's mark says it.
        case .finished where agent.asksToArchive: kind = .asksToArchive
        // Read or unread, one tick (#1323, #2363): the bold title alone says unread.
        case .finished: kind = .done
        case .stopped where agent.asksToArchive: kind = .asksToArchive
        // In the accent as the rest, not the grey `StatusIcon` (#630).
        // A queued helper waits for a free place, not on anything it asked for (#630).
        case .waiting where agent.state == .queued: kind = .queued
        case .waiting: kind = .waiting
        case .stopped: kind = .paused
        default: return nil
        }
    }

    /// The well grows with the text beside it (#750), so the row keeps its shape.
    @ScaledMetric private var scale: CGFloat = 1
    /// On a row filled with the accent, the ground as the other marks (#2382).
    @Environment(\.drawsOnAccent) private var onAccent

    var body: some View {
        Group {
            switch kind {
            case .needsYou:
                Image(systemName: "hand.raised.fill").sidebarMark(StateTint.attention.style(or: .secondary))
            case .working:
                // In the accent as the other marks (#1558, #2044); one ring for both
                // activities (#2332).
                WorkingRing(size: 14 * scale, color: onAccent ? Paper.ground : Paper.accent, doing: tool != nil)
            case .queued:
                Image(systemName: "list.number").sidebarMark(Paper.accent)
            case .waiting:
                // The waiting card's beacon, breathing in step with every other (#2456, #2657).
                WaitingBeacon(size: 14 * scale, color: onAccent ? Paper.ground : Paper.accent)
            case .paused:
                Image(systemName: "pause.circle").sidebarMark(Paper.accent)
            case .done:
                Image(systemName: "checkmark").sidebarMark(Paper.accent)
            case .asksToArchive:
                Image(systemName: ArchiveRequestWords.symbol).sidebarMark(StateTint.attention.style(or: .secondary))
            }
        }
        // Decorative: a mark filling the rows' 20-point well, as `WorkflowMark` (FR-015).
        .glyph(size: 14)
        .frame(width: 20 * scale, height: 20 * scale)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }

    private var label: String {
        switch kind {
        case .needsYou: StatusShape.words(row: agent, isComingBack: false)
        case .working: tool.map(RunningToolWords.label) ?? "Working"
        case .queued: "Queued"
        case .waiting: "Waiting"
        case .paused: "Paused"
        case .done: "Done"
        case .asksToArchive: ArchiveRequestWords.mark
        }
    }
}

/// One workflow under its folder: its name, and at its end when it last ran, as a
/// session's row has its time (#755), or nothing if it never has: off is its pause mark,
/// said to VoiceOver (#100). What it does is its page's to say (#495). Its page opens in
/// the detail as a session's chat does.
struct SidebarWorkflowRow: View {
    @Environment(RemoteModel.self) private var model
    let summary: WorkflowSummary
    let folder: FolderKey
    /// In its folder's Workflows fold: one level in, under the word Workflows (#1079).
    var isNested = false
    @State private var confirmsDelete = false
    /// The mark's well and the gap after it, as a session's row has them (#750).
    @ScaledMetric private var scale: CGFloat = 1

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            WorkflowMark(summary: summary)
            VStack(alignment: .leading, spacing: 3) {
                // Heavier only while it waits for an OK (#520), as a session's title is while unread.
                Text(summary.workflow.name)
                    .appText(.supporting)
                    .fontWeight(summary.awaitingApproval != nil && !summary.isArchived ? .semibold : .regular)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            // Its runs send no notifications (#2003), as on the Mac.
            if summary.workflow.isMuted, !summary.isArchived {
                Image(systemName: MuteWords.symbol)
                    .appText(.fine)
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel(MuteWords.muted)
            }
            // A running one counts from when this run started (#755).
            if let at = summary.lastFiredAt {
                ActivityTime(date: at)
            }
        }
        .padding(.leading, isNested ? 20 * scale + 10 : 0)
        .accessibilityElement(children: .combine)
        .accessibilityValue(!summary.isEnabled && !summary.isArchived ? "turned off" : "")
        .tag(SidebarItem.workflow(summary.id, in: folder))
        // Pin or Unpin (#432), from the leading edge, as a session's row has it.
        .swipeActions(edge: .leading) {
            if !summary.isArchived {
                PinWorkflowButton(summary: summary).tint(Paper.accent)
            }
        }
        .swipeActions(edge: .trailing) {
            if summary.isArchived {
                Button("Unarchive", systemImage: "arrow.uturn.backward") {
                    Task { await model.setWorkflowArchived(summary, false) }
                }
            } else {
                Button("Archive", systemImage: "archivebox") {
                    Task { await model.setWorkflowArchived(summary, true) }
                }
                .tint(.gray)
            }
        }
        .contextMenu {
            if summary.isArchived {
                Button("Unarchive", systemImage: "arrow.uturn.backward") {
                    Task { await model.setWorkflowArchived(summary, false) }
                }
            } else {
                if summary.canBeApproved {
                    Button("Approve", systemImage: "checkmark.shield") {
                        Task { await model.approveWorkflow(summary) }
                    }
                }
                // Not on this host, without archiving it everywhere (#391).
                if summary.canBeDenied {
                    Button("Deny on This Machine", systemImage: "hand.raised.slash") {
                        Task { await model.denyWorkflow(summary) }
                    }
                }
                if !summary.isUnapproved && summary.runsHere {
                    Button("Run now", systemImage: "play") { Task { await model.runWorkflow(summary) } }
                        .disabled(summary.isRunning)
                }
                PinWorkflowButton(summary: summary)
                if model.isPinned(summary) {
                    let ids = model.pinnedWorkflows(in: summary.folder)
                    Button("Move Up", systemImage: "arrow.up") { step(-1, in: ids) }
                        .disabled(ids.first == summary.workflowID || model.isStale)
                    Button("Move Down", systemImage: "arrow.down") { step(1, in: ids) }
                        .disabled(ids.last == summary.workflowID || model.isStale)
                }
                Button(summary.isEnabled ? "Turn Off" : "Turn On",
                       systemImage: summary.isEnabled ? "pause.circle" : "play.circle") {
                    Task { await model.setWorkflowEnabled(summary, !summary.isEnabled) }
                }
                if model.canMute(summary) {
                    let muted = summary.workflow.isMuted
                    Button {
                        Task { await model.setWorkflowMuted(summary, !muted) }
                    } label: {
                        Label(MuteWords.label(muted: muted), systemImage: MuteWords.symbol(muted: muted))
                        // What it does, under it (#2086).
                        Text(MuteWords.workflowHelp(muted: muted))
                    }
                }
                Button("Archive", systemImage: "archivebox") { Task { await model.setWorkflowArchived(summary, true) } }
            }
            Divider()
            Button("Delete…", systemImage: "trash", role: .destructive) { confirmsDelete = true }
        }
        .confirmationDialog("Delete \"\(summary.workflow.name)\"? Its file is removed from disk.",
                            isPresented: $confirmsDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { Task { await model.deleteWorkflow(summary) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The file can be restored from the folder's git history.")
        }
    }

    private func step(_ by: Int, in ids: [String]) {
        var ids = ids
        guard let index = ids.firstIndex(of: summary.workflowID), ids.indices.contains(index + by) else { return }
        ids.swapAt(index, index + by)
        Task { await model.arrangeWorkflowPins(ids, in: summary.folder) }
    }
}

/// Pin or Unpin a workflow (#432): in its row's menu, its leading swipe, and its page.
struct PinWorkflowButton: View {
    @Environment(RemoteModel.self) private var model
    let summary: WorkflowSummary

    var body: some View {
        let pinned = model.isPinned(summary)
        Button {
            Task { await model.setPinned(summary, !pinned) }
        } label: {
            Label(pinned ? "Unpin" : "Pin", systemImage: pinned ? "pin.slash" : "pin")
        }
        .disabled(model.isStale)
    }
}

/// Whether a workflow is running, waiting, refused or put away: in the accent, as every
/// icon in the sidebar is (#495), and the attention colour when it needs a person.
struct WorkflowMark: View {
    let summary: WorkflowSummary

    /// The well grows with the text beside it (#750), so the row keeps its shape.
    @ScaledMetric private var scale: CGFloat = 1
    /// On a row filled with the accent, the ground as the other marks (#2382).
    @Environment(\.drawsOnAccent) private var onAccent

    var body: some View {
        Group {
            if summary.isRunning {
                SyncedSpinner(diameter: 14 * scale, color: onAccent ? Paper.ground : Paper.accent)
            } else {
                Image(systemName: symbol)
                    // Decorative: the workflow's mark filling a 20-point well, not text (FR-015).
                    .glyph(size: 14)
                    // In the accent, as the sidebar's icons are, unless it wants a person (#495).
                    .sidebarMark(summary.needsAPerson ? StateTint.attention.style(or: .secondary)
                                 : AnyShapeStyle(Paper.accent))
            }
        }
        .frame(width: 20 * scale, height: 20 * scale)
        .accessibilityHidden(true)
    }

    private var symbol: String {
        if summary.isArchived { return "archivebox" }
        // A shield, not a hand (#587): the hand is a session's Needs You mark, and a
        // workflow waiting for an OK beside it read as one more session asking.
        if summary.awaitingApproval != nil { return "checkmark.shield" }
        if summary.deniedHere != nil { return "xmark.shield" }
        if !summary.isEnabled { return "pause.circle" }
        // Waiting behind a run is not something wrong (#422).
        if summary.queued > 0 { return "tray.full" }
        if case .refused = summary.lastOutcome { return "exclamationmark.triangle" }
        // A bot's workflow heard here (#2027).
        if !summary.runsHere { return "ear" }
        // An alarm clock for a schedule, a flowchart otherwise (#765): a plain clock read as
        // a session's Waiting.
        if summary.nextFireAt != nil { return "alarm" }
        // Run only by hand (#432).
        if summary.workflow.runsOnlyByHand { return "hand.tap" }
        if !summary.workflow.canFire { return "circle.dotted" }
        return "flowchart"
    }
}

/// A folder's pinned pages (#159), first in its fold, right under the folder's row. A long
/// press moves or unpins one; in the list's edit mode they drag.
struct PinnedPageRows: View {
    @Environment(RemoteModel.self) private var model
    let folder: FolderKey

    var body: some View {
        let pins = model.pins(in: folder.folder)
        ForEach(Array(pins.enumerated()), id: \.element.path) { index, pin in
            HStack(spacing: 8) {
                Image(systemName: pin.kind == .view ? "square.grid.2x2" : pin.kind == .html ? "globe" : "doc.text")
                    .sidebarMark(Paper.accent)
                    .frame(width: 20)
                    .accessibilityHidden(true)
                Text(pin.title)
                    .lineLimit(1)
                    .foregroundStyle(pin.missing ? .secondary : .primary)
                // Nothing at its end (#587), which is only a session's: missing is the
                // grey title, and VoiceOver's.
                Spacer(minLength: 4)
            }
            .appText(.supporting)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(pin.title), pinned \(pin.kind == .view ? "view" : "page")" + (pin.missing ? ", missing" : ""))
            .tag(SidebarItem.pin(pin.path, in: folder))
            .contextMenu {
                Button("Move Up", systemImage: "arrow.up") { step(pin, -1, in: pins) }
                    .disabled(index == 0)
                Button("Move Down", systemImage: "arrow.down") { step(pin, 1, in: pins) }
                    .disabled(index == pins.count - 1)
                Button("Unpin", systemImage: "pin.slash", role: .destructive) {
                    Task { await model.unpin(pin.path, in: folder.folder) }
                }
            }
        }
        .onMove { from, to in
            var paths = pins.map(\.path)
            paths.move(fromOffsets: from, toOffset: to)
            Task { await model.arrangePins(paths, in: folder.folder) }
        }
    }

    private func step(_ pin: PinView, _ by: Int, in pins: [PinView]) {
        var paths = pins.map(\.path)
        guard let index = paths.firstIndex(of: pin.path), paths.indices.contains(index + by) else { return }
        paths.swapAt(index, index + by)
        Task { await model.arrangePins(paths, in: folder.folder) }
    }
}

/// A connected server's list views (#2032), after the folder's pins: a row each, named by
/// the service ("GitHub · Issues"), without a pin. A long press hides one; the folder's
/// long press shows them again.
struct ServerViewRows: View {
    @Environment(RemoteModel.self) private var model
    let folder: FolderKey

    var body: some View {
        ForEach(model.serverViews(in: folder.folder).filter { $0.hidden != true }) { view in
            HStack(spacing: 8) {
                Image(systemName: "square.grid.2x2")
                    .sidebarMark(Paper.accent)
                    .frame(width: 20)
                    .accessibilityHidden(true)
                Text(view.title)
                    .lineLimit(1)
                Spacer(minLength: 4)
                // Its server's count (#2033), grey as a fold's count.
                if let count = view.count {
                    Text("\(count)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .appText(.supporting)
            .accessibilityElement(children: .ignore)
            // VoiceOver says the count (#590).
            .accessibilityLabel("\(view.title), view" + (view.count.map { ", \($0)" } ?? ""))
            .tag(SidebarItem.pin(view.path, in: folder))
            .contextMenu {
                Button("Hide", systemImage: "eye.slash") {
                    Task { await model.setViewHidden(view.path, true, in: folder.folder) }
                }
            }
        }
    }
}

/// The folder's long press: every server view hidden in it, back in the sidebar (#2032).
/// Left out when none is hidden.
struct ShowHiddenViewsButton: View {
    @Environment(RemoteModel.self) private var model
    let summary: DaemonAPI.FolderSummary

    var body: some View {
        let hidden = model.serverViews(in: summary.folder.folder).filter { $0.hidden == true }
        if !hidden.isEmpty {
            Button {
                Task {
                    for view in hidden { await model.setViewHidden(view.path, false, in: summary.folder.folder) }
                }
            } label: {
                Label("Show Hidden Views (\(hidden.count))", systemImage: "eye")
            }
            .disabled(model.isStale(on: summary.host))
        }
    }
}
