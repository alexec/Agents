import AgentsKitCore
import SwiftUI

/// One session under its project: the Mac's compact `AgentRow`, tagged into the sidebar's
/// one selection (#226). A swipe from the leading edge pins it, from the trailing edge
/// archives it or brings it back, and a long press is the Mac's row menu.
struct SidebarSessionRow: View {
    @Environment(RemoteModel.self) private var model
    /// The agent as the list had it when it drew this row. Only its id is trusted.
    private let given: Agent
    /// Which project it is in, after the title: under a smart group of the sidebar
    /// (#495, #498), which gathers sessions from every project, and nowhere else.
    private let place: String?

    init(agent: Agent, place: String? = nil) {
        given = agent
        self.place = place
    }

    /// The agent as the phone has it now, read from the model rather than kept: see the
    /// Mac's `AgentRow`.
    private var agent: Agent { model.work.agent(given.id) ?? given }

    private var startedByWorkflowName: String? {
        guard let id = agent.startedByWorkflow else { return nil }
        return model.work.workflows(in: agent.projectFolder)
            .first { $0.workflow.workflowID == id }?.workflow.name ?? id
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // What it wants, as the window's sidebar says it (#495): the state is the
            // row's mark, unread among them. Any other state keeps its icon.
            if let mark = SessionMark(agent: agent, group: model.work.group(of: agent)) {
                mark
            } else {
                StatusIcon(state: agent.state, isComingBack: model.isComingBack(agent),
                           outcome: agent.report?.outcome,
                           isWaiting: agent.isWaiting,
                           endedReason: agent.endedReason,
                           outcomeUnknown: agent.endingIsUnaccountedFor)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(agent.title ?? "Untitled")
                        .appText(.supporting)
                        .fontWeight(agent.showsUnread ? .semibold : .regular)
                        .lineLimit(1)
                    if let place {
                        Text(place)
                            .appText(.fine)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            // Whole, the title giving way first (#587): cut to "p" it said nothing.
                            .fixedSize()
                            .layoutPriority(-1)
                    }
                    // Started by a workflow (the Mac row's mark), then by another agent.
                    if let workflowName = startedByWorkflowName {
                        Image(systemName: "clock.arrow.circlepath")
                            .appText(.fine)
                            .foregroundStyle(.tertiary)
                            .accessibilityLabel("started by the workflow \(workflowName)")
                    }
                    if model.startedByAgentLabel(agent) != nil {
                        Image(systemName: AgentsModel.startedByAgentSymbol)
                            .appText(.fine)
                            .foregroundStyle(.tertiary)
                    }
                }
                // The agent's own account of its last turn, one line, as on the Mac.
                if let acting = model.acting(agent.id) {
                    Telling(host: model.answerRecipient(agent.id), doing: acting.doing)
                } else if let queued = model.queuedLine(agent) {
                    // Its place in its project's queue (#362), as the Mac's row says it.
                    Text(queued)
                        .appText(.fine)
                        .foregroundStyle(.secondary)
                } else if agent.missingFolder != nil, agent.state != .archived {
                    Text(MissingFolderWords.label)
                        .appText(.fine)
                        .foregroundStyle(.secondary)
                } else if let report = agent.report?.message {
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
            // When it last did anything, as the page's row has it (#341).
            ActivityTime(date: agent.lastActivityAt)
        }
        // Last known, not current: its host is not answering.
        .opacity(model.isStale(agent) ? 0.55 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityValue(agent.showsUnread ? "unread" : "")
        .tag(SidebarItem.session(agent.id))
        .contextMenu { AgentMenuItems(agent: agent) }
        // Pin or Unpin (#180), from the leading edge, as on the Mac.
        .swipeActions(edge: .leading) {
            if agent.state != .archived {
                PinAgentButton(agent: agent).tint(Paper.accent)
            }
        }
        // Archive or Bring Back, and Mark as Read or Unread, from the trailing edge. A long
        // swipe archives, as in Mail.
        .swipeActions(edge: .trailing, allowsFullSwipe: agent.state != .archived) {
            if agent.state == .archived {
                BringBackAgentButton(agent: agent)
            } else {
                ArchiveAgentButton(agent: agent).tint(.gray)
                if agent.state == .finished {
                    MarkReadButton(agent: agent).tint(Paper.accent)
                }
            }
        }
    }
}

/// A session's mark in the sidebar (#495, #498), the window's: what it wants, in four
/// shapes — an orange hand when it needs the person, a spinner while it works, two rings
/// when it finished unread, an empty ring once read. Any other state keeps its
/// `StatusIcon`.
private struct SessionMark: View {
    private enum Kind { case needsYou, working, unread, read, asksToArchive }
    private let kind: Kind

    init?(agent: Agent, group: AgentGroup) {
        switch group {
        case .needsAttention, .blocked: kind = .needsYou
        case .running: kind = .working
        // Asking to be archived (#584), as the window's mark says it.
        case .finished where agent.asksToArchive: kind = .asksToArchive
        case .finished: kind = agent.showsUnread ? .unread : .read
        case .stopped where agent.asksToArchive: kind = .asksToArchive
        default: return nil
        }
    }

    var body: some View {
        Group {
            switch kind {
            case .needsYou:
                Image(systemName: "hand.raised.fill").tinted(.attention)
            case .working:
                SyncedSpinner(diameter: 14)
            case .unread:
                Image(systemName: "circle.inset.filled").foregroundStyle(Paper.accent)
            case .read:
                Image(systemName: "circle").foregroundStyle(Paper.accent)
            case .asksToArchive:
                Image(systemName: ArchiveRequestWords.symbol).foregroundStyle(Paper.accent)
            }
        }
        // Decorative: a mark filling the rows' 20-point well, as `WorkflowMark` (FR-015).
        .font(.system(size: 14))
        .frame(width: 20, height: 20)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }

    private var label: String {
        switch kind {
        case .needsYou: "Needs you"
        case .working: "Working"
        case .unread: "Unread"
        case .read: "Done"
        case .asksToArchive: ArchiveRequestWords.mark
        }
    }
}

/// One workflow under its project: its name, and nothing at its end, which is only a
/// session's (#587): off is its pause mark, said to VoiceOver (#100). What it does is
/// its page's to say (#495). Its page opens in the detail as a session's chat does.
struct SidebarWorkflowRow: View {
    @Environment(RemoteModel.self) private var model
    let summary: WorkflowSummary
    let project: ProjectKey

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
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(!summary.isEnabled && !summary.isArchived ? "turned off" : "")
        .tag(SidebarItem.workflow(summary.id, in: project))
        // Pin or Unpin (#432), from the leading edge, as a session's row has it.
        .swipeActions(edge: .leading) {
            if !summary.isArchived {
                PinWorkflowButton(summary: summary).tint(Paper.accent)
            }
        }
        .swipeActions(edge: .trailing) {
            if summary.isArchived {
                Button("Bring Back", systemImage: "arrow.uturn.backward") {
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
                Button("Bring Back", systemImage: "arrow.uturn.backward") {
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
                    Button("Deny on This Host", systemImage: "hand.raised.slash") {
                        Task { await model.denyWorkflow(summary) }
                    }
                }
                if !summary.isUnapproved {
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
                Button("Archive", systemImage: "archivebox") { Task { await model.setWorkflowArchived(summary, true) } }
            }
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

    var body: some View {
        Group {
            if summary.isRunning {
                SyncedSpinner(diameter: 14)
            } else {
                Image(systemName: symbol)
                    // Decorative: the workflow's mark filling a 20-point well, not text (FR-015).
                    .font(.system(size: 14))
                    // In the accent, as the sidebar's icons are, unless it wants a person (#495).
                    .foregroundStyle(summary.needsAPerson ? StateTint.attention.style(or: .secondary)
                                     : AnyShapeStyle(Paper.accent))
            }
        }
        .frame(width: 20, height: 20)
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
        if summary.nextFireAt != nil { return "clock" }
        // Run only by hand (#432).
        if summary.workflow.runsOnlyByHand { return "hand.tap" }
        return "circle.dotted"
    }
}

/// A project's pinned pages (#159), first in its fold, right under the project's row. A long
/// press moves or unpins one; in the list's edit mode they drag.
struct PinnedPageRows: View {
    @Environment(RemoteModel.self) private var model
    let project: ProjectKey

    var body: some View {
        let pins = model.pins(in: project.folder)
        ForEach(Array(pins.enumerated()), id: \.element.path) { index, pin in
            HStack(spacing: 8) {
                Image(systemName: pin.kind == .view ? "square.grid.2x2" : pin.kind == .html ? "globe" : "doc.text")
                    .foregroundStyle(Paper.accent)
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
            .tag(SidebarItem.pin(pin.path, in: project))
            .contextMenu {
                Button("Move Up", systemImage: "arrow.up") { step(pin, -1, in: pins) }
                    .disabled(index == 0)
                Button("Move Down", systemImage: "arrow.down") { step(pin, 1, in: pins) }
                    .disabled(index == pins.count - 1)
                Button("Unpin", systemImage: "pin.slash", role: .destructive) {
                    Task { await model.unpin(pin.path, in: project.folder) }
                }
            }
        }
        .onMove { from, to in
            var paths = pins.map(\.path)
            paths.move(fromOffsets: from, toOffset: to)
            Task { await model.arrangePins(paths, in: project.folder) }
        }
    }

    private func step(_ pin: PinView, _ by: Int, in pins: [PinView]) {
        var paths = pins.map(\.path)
        guard let index = paths.firstIndex(of: pin.path), paths.indices.contains(index + by) else { return }
        paths.swapAt(index, index + by)
        Task { await model.arrangePins(paths, in: project.folder) }
    }
}
