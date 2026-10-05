import AgentsKitCore
import SwiftUI

/// One session under its project: the Mac's compact `AgentRow`, tagged into the sidebar's
/// one selection (#226). A swipe from the leading edge pins it, from the trailing edge
/// archives it or brings it back, and a long press is the Mac's row menu.
struct SidebarSessionRow: View {
    @Environment(RemoteModel.self) private var model
    /// The agent as the list had it when it drew this row. Only its id is trusted.
    private let given: Agent

    init(agent: Agent) {
        given = agent
    }

    /// The agent as the phone has it now, read from the model rather than kept: see the
    /// Mac's `AgentRow`.
    private var agent: Agent { model.work.agent(given.id) ?? given }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            StatusIcon(state: agent.state, isComingBack: model.isComingBack(agent),
                       outcome: agent.report?.outcome,
                       isWaiting: agent.isWaiting,
                       endedReason: agent.endedReason,
                       outcomeUnknown: agent.endingIsUnaccountedFor,
                       isParked: agent.parking?.isParked == true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    // Unread is a mark on the row, never a group (#70).
                    if agent.showsUnread {
                        Circle()
                            .fill(.secondary)
                            .frame(width: 7, height: 7)
                            .alignmentGuide(.firstTextBaseline) { $0[.bottom] }
                            .accessibilityHidden(true)
                    }
                    Text(agent.title ?? "Untitled")
                        .appText(.supporting)
                        .fontWeight(agent.showsUnread ? .semibold : .regular)
                        .lineLimit(1)
                    if model.startedByAgentLabel(agent) != nil {
                        Image(systemName: AgentsModel.startedByAgentSymbol)
                            .appText(.fine)
                            .foregroundStyle(.tertiary)
                    }
                }
                // The agent's own account of its last turn, one line, as on the Mac.
                if let acting = model.acting(agent.id) {
                    Telling(host: "your Mac", doing: acting.doing)
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
                // Its worktree (030) and labels, on their own line so a long branch never
                // cuts the title short (#68).
                if agent.worktree != nil || !agent.labels.isEmpty {
                    WrappingHStack(spacing: 5) {
                        if let worktree = agent.worktree {
                            HStack(spacing: 3) {
                                Image(systemName: "arrow.triangle.branch")
                                Text(worktree.name).lineLimit(1)
                                    .strikethrough(agent.missingFolder != nil)
                            }
                            .appText(.fine)
                            .foregroundStyle(.tertiary)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("in worktree \(worktree.name)")
                        }
                        ForEach(agent.labels, id: \.normalizedValue) { LabelChip(label: $0) }
                    }
                }
                if let leases = model.work.leaseStatus(of: agent.id) {
                    LeaseMark(status: leases)
                }
                if let running = BackgroundWords.mark(agent.background) {
                    Text(running)
                        .appText(.fine)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if agent.state == .archived,
                   let note = RetirementWords.rowNote(agent.retirement, now: Date(),
                                                      cap: model.work.retentionState?.settings.cap) {
                    Text(note)
                        .appText(.fine)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if agent.eventWait?.isOpen == true, let wait = model.work.waitStatus(of: agent) {
                    Text(wait.mark)
                        .appText(.fine)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                ForEach(model.blockLines(agent), id: \.self) { line in
                    Text(line)
                        .appText(.fine)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let line = ParkWords.line(agent.parking) {
                    Text(line)
                        .appText(.fine)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
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

/// One workflow under its project: its name, what it is, and Off where it is (#100).
/// Its page opens in the detail as a session's chat does.
struct SidebarWorkflowRow: View {
    @Environment(RemoteModel.self) private var model
    let summary: WorkflowSummary
    let project: ProjectKey

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            WorkflowMark(summary: summary)
            VStack(alignment: .leading, spacing: 3) {
                Text(summary.workflow.name)
                    .appText(.supporting).fontWeight(.semibold)
                    .lineLimit(1)
                Text(summary.workflow.summary)
                    .appText(.fine)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if !summary.isEnabled, !summary.isArchived {
                Text("Off")
                    .appText(.fine)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .tag(SidebarItem.workflow(summary.id, in: project))
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
                // Approving is the Mac's, for now; running a file nobody has approved
                // would only be refused.
                if summary.awaitingApproval == nil {
                    Button("Run now", systemImage: "play") { Task { await model.runWorkflow(summary) } }
                        .disabled(summary.isRunning)
                }
                Button(summary.isEnabled ? "Turn Off" : "Turn On",
                       systemImage: summary.isEnabled ? "pause.circle" : "play.circle") {
                    Task { await model.setWorkflowEnabled(summary, !summary.isEnabled) }
                }
                Button("Archive", systemImage: "archivebox") { Task { await model.setWorkflowArchived(summary, true) } }
            }
        }
    }
}

/// Whether a workflow is running, waiting, refused or put away. Grey, all of it: the
/// app's one colour means something needs a person.
struct WorkflowMark: View {
    let summary: WorkflowSummary

    var body: some View {
        Group {
            if summary.isRunning {
                SyncedSpinner(diameter: 14)
            } else {
                Image(systemName: symbol)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 20, height: 20)
        .accessibilityHidden(true)
    }

    private var symbol: String {
        if summary.isArchived { return "archivebox" }
        if summary.awaitingApproval != nil { return "hand.raised" }
        if !summary.isEnabled { return "pause.circle" }
        if case .refused = summary.lastOutcome { return "exclamationmark.triangle" }
        if summary.nextFireAt != nil { return "clock" }
        return "circle.dotted"
    }
}

/// A project's pinned pages (#159), first in its fold, right under the row that opens its
/// Dashboard. A long press moves or unpins one; in the list's edit mode they drag.
struct PinnedPageRows: View {
    @Environment(RemoteModel.self) private var model
    let project: ProjectKey

    var body: some View {
        let pins = model.pins(in: project.folder)
        ForEach(Array(pins.enumerated()), id: \.element.path) { index, pin in
            HStack(spacing: 8) {
                Image(systemName: pin.kind == .html ? "globe" : "doc.text")
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                    .accessibilityHidden(true)
                Text(pin.title)
                    .lineLimit(1)
                    .foregroundStyle(pin.missing ? .secondary : .primary)
                Spacer(minLength: 4)
                if pin.missing {
                    Text("Missing").appText(.fine).foregroundStyle(.tertiary)
                }
            }
            .appText(.supporting)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(pin.missing ? "\(pin.title), pinned page, missing" : "\(pin.title), pinned page")
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
