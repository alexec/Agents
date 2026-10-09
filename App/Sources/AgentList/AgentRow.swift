import AgentsKitCore
import SwiftUI

/// One agent on a project page: what it is, and what it is doing.
///
/// An icon for the state, the name it was given, and a line saying what it is working
/// on. The name is what it was asked; the line under it is what is happening now, which
/// is the thing you came to find out.
struct AgentRow: View {
    @Environment(AppModel.self) private var model
    /// The agent as the list had it when it drew this row. Only its id is trusted.
    private let given: Agent
    /// A row of the Mac's sessions list rather than a card on a page: a list-sized
    /// title and one line of what it said, so a column of them reads at a glance.
    private let isCompact: Bool
    /// Which project it is in, after the title: under a smart row of the sidebar (#495),
    /// which gathers sessions from every project, and nowhere else.
    private let place: String?

    init(agent: Agent, isCompact: Bool = false, place: String? = nil) {
        given = agent
        self.isCompact = isCompact
        self.place = place
    }

    /// The agent as the window has it now, read from the model rather than kept.
    ///
    /// A row that drew the copy it was handed stayed on that copy: a card that moved
    /// between groups in the lazy stack kept its first render, so a finished agent sat
    /// under Complete with a spinner and its first title, and one prompted again sat
    /// under Working with a tick. The heading was right, because it is counted from the
    /// model; the row was not, because nothing made the stack hand it the new copy.
    /// Reading the model here makes this row observe the agent itself. By id, from the
    /// model's index rather than a pass over every agent held: `agent` is read dozens of
    /// times a row (#135).
    private var agent: Agent { model.work.agent(given.id) ?? given }

    var body: some View {
        rowContent
            // Last known, not current: its host is not answering (037), or the control
            // plane that would carry the answer is away (058, frame H).
            .opacity(model.hostUnreachable(agent.host) ? 0.55 : 1)
            .confirmationDialog(DeletionWords.confirmTitle(agent.title), isPresented: $deleting) {
                Button("Delete", role: .destructive) {
                    Task {
                        if case .failure(let refusal) = await model.delete(agent.id) { cannotDelete = refusal.message }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(DeletionWords.confirmMessage)
            }
            .alert("This session cannot be deleted yet",
                   isPresented: Binding(get: { cannotDelete != nil }, set: { if !$0 { cannotDelete = nil } })) {
                Button("OK") {}
            } message: {
                Text(cannotDelete ?? "")
            }
    }

    @ViewBuilder
    private var rowContent: some View {
        // In the sidebar, the icon column every row there has (#495): 16 wide, 6 to the title.
        HStack(alignment: .top, spacing: isCompact ? 6 : 12) {
            if isCompact, let mark = SessionMark(agent: agent, group: model.work.group(of: agent)) {
                mark.padding(.top, 1)
            } else {
            StatusIcon(state: agent.state, isComingBack: isComingBack,
                       outcome: agent.report?.outcome,
                       isWaiting: agent.isWaiting,
                       isUnaccountedFor: agent.endingIsUnaccountedFor,
                       ending: agent.endedReason?.summary,
                       endedReason: agent.endedReason,
                       isUnread: agent.isUnread,
                       isParked: agent.parking?.isParked == true)
                .frame(width: isCompact ? 16 : nil)
                .padding(.top, 1)
            }

            VStack(alignment: .leading, spacing: isCompact ? 4 : 3) {
                HStack(spacing: 5) {
                    // Unread is a mark on the row, as in Mail, and never a group (#70): a
                    // dot and a heavier title, both gone once it is opened, and the row
                    // where it was. Said as the title's value, not as a label over the
                    // row, which would stack on the Text's own (one element per row).
                    // In the sidebar the mark says unread (#495); the dot is the page's.
                    if agent.showsUnread, !isCompact {
                        UnreadDot()
                    }
                    Text(agent.title ?? "Untitled")
                        .appText(isCompact ? .supporting : .reading)
                        .fontWeight(agent.showsUnread ? .semibold : .regular)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .accessibilityValue(agent.showsUnread ? "unread" : "")
                    if let place {
                        Text(place)
                            .appText(.fine)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .layoutPriority(-1)
                    }
                    // Started by a workflow rather than a person: the one thing about
                    // an agent's origin worth a mark, because it is the difference
                    // between something you asked for and something that ran itself.
                    if let workflowName = startedByWorkflowName {
                        Image(systemName: "clock.arrow.circlepath")
                            .appText(.fine)
                            .foregroundStyle(.tertiary)
                            .help("Started by the workflow \(workflowName)")
                            .accessibilityLabel("started by the workflow \(workflowName)")
                    }
                    // Started by another agent (028): the same kind of mark, for the
                    // same reason — this is not something the person typed for.
                    if let starter = model.startedByAgentLabel(agent) {
                        Image(systemName: AgentsModel.startedByAgentSymbol)
                            .appText(.fine)
                            .foregroundStyle(.tertiary)
                            .help(starter)
                            .accessibilityLabel(starter)
                    }
                }

                // The agent's own account of its last turn, and nothing else. This line
                // used to be whichever of five things was true — a plan step, the
                // report, "Waiting for your answer", why it stopped — with the runtime
                // and a step count under it, and a row that says a different kind of
                // thing depending on state is a row nobody can read at a glance. The
                // state is the icon's; what it is doing is the title, which the agent
                // keeps current; this is what it said.
                // Stop, park or archive on its way, from whichever control sent it (#87).
                // In the report's place, at the report line's height. Nothing is held for
                // the line when there is none (#144): the row is fixed to its height below,
                // so the list measures it again when a line arrives.
                if let acting = model.acting(agent.id) {
                    Telling(host: model.answerRecipient(agent.id), doing: acting.doing)
                        .frame(height: isCompact ? 14 : nil)
                } else if let queued = model.queuedLine(agent) {
                    // Its place in its project's queue (#362), in the report's place: it
                    // has said nothing yet, and starts by itself when a place frees.
                    Text(queued)
                        .appText(isCompact ? .fine : .supporting)
                        .foregroundStyle(.secondary)
                        .help("Starts by itself when this project has a place free for another helper")
                } else if agent.missingFolder != nil, agent.state != .archived {
                    // Its folder gone (#119): said before anybody types, as a project's
                    // row says it, in the report's place.
                    Text(MissingFolderWords.label)
                        .appText(isCompact ? .fine : .supporting)
                        .foregroundStyle(.secondary)
                        .help(agent.folderGoneMessage)
                } else if let report = agent.report?.message {
                    // In the sidebar, white as the title is (#495): what it said is
                    // what the row is for.
                    Text(report)
                        .appText(isCompact ? .fine : .supporting)
                        .foregroundStyle(isCompact ? .primary : .secondary)
                        .lineLimit(isCompact ? 1 : 2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // Working in a worktree (030): named, because with two agents in one
                // project the worktree is how you tell whose changes are whose. On this
                // line, not the title's, so a long branch never cuts the title short (#68).
                // Labels are shown here and changed over the chat.
                if agent.worktree != nil || !agent.labels.isEmpty {
                    WrappingHStack(spacing: 5) {
                        if let worktree = agent.worktree {
                            // Gone is the daemon's mark on the record, which it keeps by a stat on
                            // its heartbeat and when it removes a worktree: the row asks nothing
                            // of the host itself, so a long list costs no folder listings (#176).
                            WorktreeBadge(worktree: worktree, isGone: agent.missingFolder != nil)
                        }
                        ForEach(agent.labels, id: \.normalizedValue) { LabelChip(label: $0) }
                    }
                }

                // What it holds or waits for (036), so an idle agent still holding the
                // simulator can be seen from the list.
                if let leases = model.work.leaseStatus(of: agent.id) {
                    LeaseMark(status: leases)
                }

                // What it has running in the background (057), on the same kind of line.
                if let running = BackgroundWords.mark(agent.background) {
                    Label(running, systemImage: "apple.terminal")
                        .appText(.fine)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(running)
                }

                // Waiting on events (042), on the same kind of line.
                if agent.eventWait?.isOpen == true, let wait = model.work.waitStatus(of: agent) {
                    Text(wait.mark)
                        .appText(.fine)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                // Blocked (039): what it waits on, one line an agent, and when it will
                // look again — so the row says what it is waiting for without opening
                // it (SC-005). Carry on is here because the person often knows the block
                // has gone before the app does.
                if model.isBlocked(agent) {
                    ForEach(model.blockLines(agent), id: \.self) { line in
                        Text(line)
                            .appText(.fine)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Button(AgentsModel.carryOnLabel) { Task { await model.carryOn(agent.id) } }
                        .buttonStyle(.paper)
                        .controlSize(.small)
                        .padding(.top, 3)
                        .help(AgentsModel.carryOnHelp(for: agent))
                }
                // Parked, and since when; or that it will park when this turn ends
                // (040). How it ended stays the icon's to say.
                if let line = ParkWords.line(agent.parking) {
                    Text(line)
                        .appText(.fine)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
            // When it last did anything, as the page's row has it (#341).
            ActivityTime(date: agent.lastActivityAt)
                .padding(.top, 1)
        }
        .fixedSize(horizontal: false, vertical: true)
        .contextMenu {
            if model.isBlocked(agent) {
                Button(AgentsModel.carryOnLabel) { Task { await model.carryOn(agent.id) } }
            }
            if model.canStop(agent) {
                Button("Stop") { Task { await model.stop(agent.id) } }
                    .disabled(isActing)
            }
            if agent.state == .archived {
                Button("Bring Back") { Task { await model.unarchive(agent.id) } }
                // Gone for good (#398), asked first; the daemon says why not when it cannot.
                Button("Delete…", role: .destructive) { deleting = true }
            } else {
                // The person's own mark (#70): leave something to come back to, or
                // clear it without opening it.
                if agent.state == .finished {
                    if agent.isUnread {
                        Button("Mark as Read", systemImage: "envelope.open") {
                            Task { await model.setUnread(agent.id, false) }
                        }
                    } else {
                        Button("Mark as Unread", systemImage: "envelope.badge") {
                            Task { await model.setUnread(agent.id, true) }
                        }
                    }
                }
                // At the top of its project whatever its state, or back among the rest (#180).
                PinSessionButton(agent: agent)
                // Branching leaves the original alone and carries the history so far.
                Button("Branch") { Task { await model.fork(agent.id) } }
                if let action = agent.parkAction {
                    Button(ParkWords.label(action), systemImage: ParkWords.symbol(action)) {
                        Task { await model.perform(action, on: agent.id) }
                    }
                    .help(ParkWords.help(action))
                    .disabled(isActing)
                }
                Button("Archive") { Task { await model.archive(agent.id, andLeave: true) } }
                    .disabled(isActing)
            }
            // Finder only sees this Mac's disk (058, FR-019).
            if model.isOnThisMac(agent.host) {
                Divider()
                Button("Show in Finder") {
                    model.reveal(agent.cwd, on: agent.host)
                }
            }
        }
    }

    /// Something is on its way to this agent; its menu holds until it is back (#87).
    private var isActing: Bool { model.acting(agent.id) != nil }

    @State private var deleting = false
    @State private var cannotDelete: String?
    /// Whether the daemon is bringing this chat back by itself after a restart.
    private var isComingBack: Bool { model.isComingBack(agent) }

    /// The name of the workflow that started this agent, if one did — or its id when
    /// the file has since gone, so the mark never disappears with it.
    private var startedByWorkflowName: String? {
        guard let id = agent.startedByWorkflow else { return nil }
        return model.workflows(in: agent.projectFolder).first { $0.workflow.workflowID == id }?.workflow.name ?? id
    }
}

/// What state an agent is in, as one of four shapes.
///
/// The shape is `StatusShape`'s, which the phone's card draws from too. Grey, all of
/// it, except the one that wants you: the only colour in this app means something
/// needs a person. The finer distinctions — which outcome, why it stopped, whether
/// anyone vouched for the ending — are still said, in the tooltip and to a screen
/// reader, rather than drawn.
/// A session's mark in the sidebar (Alex, #495): what it wants, in four shapes — an
/// orange hand when it needs the person, a spinner while it works, two rings when it
/// finished unread, an empty ring once read. Any other state keeps its `StatusIcon`.
private struct SessionMark: View {
    private enum Kind { case needsYou, working, unread, read }
    private let kind: Kind

    init?(agent: Agent, group: AgentGroup) {
        switch group {
        case .needsAttention, .blocked: kind = .needsYou
        case .running: kind = .working
        case .finished: kind = agent.showsUnread ? .unread : .read
        default: return nil
        }
    }

    var body: some View {
        Group {
            switch kind {
            case .needsYou:
                Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
            case .working:
                ProgressView().controlSize(.mini)
            case .unread:
                Image(systemName: "circle.inset.filled").foregroundStyle(Paper.accent)
            case .read:
                Image(systemName: "circle").foregroundStyle(Paper.accent)
            }
        }
        .frame(width: 16, height: 16)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }

    private var label: String {
        switch kind {
        case .needsYou: "Needs you"
        case .working: "Working"
        case .unread: "Unread"
        case .read: "Done"
        }
    }
}

struct StatusIcon: View {
    let state: AgentState
    /// The daemon is bringing this chat back by itself after a restart.
    var isComingBack = false
    /// What the agent said about the work, where it said anything.
    var outcome: WorkOutcome?
    /// The app will carry it on by itself (`Agent.isWaiting`): Waiting, not Blocked.
    var isWaiting = false
    /// A turn that ended cleanly, was asked how it went, and still said nothing.
    var isUnaccountedFor = false
    /// Why it stopped, where it did, in `EndedReason`'s words.
    var ending: String?
    var endedReason: EndedReason?
    /// Said in the tooltip only; the row's dot is the mark, and the shape ignores it (#70).
    var isUnread = false
    /// Parked (040): the shape still says how it ended, but it is not orange, because
    /// the person has seen it and chosen later.
    var isParked = false
    /// Waiting for an allowance to come back (052, US4): it will carry on by itself, so
    /// it does not want a person, whatever its stopped shape says.
    var isWaitingForAllowance = false

    private var shape: StatusShape {
        StatusShape(state: state, outcome: outcome, isWaiting: isWaiting, isComingBack: isComingBack,
                    endedReason: endedReason,
                    waitingForAllowance: isWaitingForAllowance,
                    outcomeUnknown: isUnaccountedFor)
    }

    var body: some View {
        Group {
            if let symbol = shape.symbol {
                Image(systemName: symbol)
                    // Decorative: a glyph filling an 18-point well, not text (FR-015).
                    .font(.system(size: 15))
                    .foregroundStyle((StatusShape.isTinted(shape, isParked: isParked, isWaitingForAllowance: isWaitingForAllowance)
                                      ? StateTint.attention : .none)
                        .style(or: .secondary))
            } else {
                SyncedSpinner(diameter: 12)
            }
        }
        .frame(width: 18, height: 18)
        .help(description)
        .accessibilityLabel(description)
    }

    /// What a screen reader hears, and what the tooltip says: `StatusShape.words`, which
    /// the web remote says too.
    private var description: String {
        StatusShape.words(shape, state: state, isComingBack: isComingBack, outcome: outcome,
                          isUnaccountedFor: isUnaccountedFor, ending: ending, isUnread: isUnread,
                          isWaitingForAllowance: isWaitingForAllowance)
    }
}

/// The unread mark before a row's title (#70). Grey, not the attention colour: unread
/// is news, not a need. Silent to a screen reader, which hears the title's value instead.
struct UnreadDot: View {
    var body: some View {
        Circle()
            .fill(.secondary)
            .frame(width: 7, height: 7)
            .accessibilityHidden(true)
    }
}

/// Which worktree an agent works in: a branch glyph and the worktree's name, quiet
/// enough to sit after a title (030).
struct WorktreeBadge: View {
    let worktree: AgentWorktree
    var isGone = false

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "arrow.triangle.branch")
            Text(worktree.name)
                .lineLimit(1)
                .strikethrough(isGone)
        }
        .appText(.fine)
        .foregroundStyle(.tertiary)
        .help(help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isGone ? "in worktree \(worktree.name), which is gone" : "in worktree \(worktree.name)")
    }

    private var help: String {
        let path = worktree.root.path(percentEncoded: false)
        let branch = worktree.branch ?? "detached"
        return isGone ? "\(branch) — \(path), which is not there any more" : "\(branch) — \(path)"
    }
}

/// Pin or Unpin a session (#180): in its row's menu and the chat's.
struct PinSessionButton: View {
    @Environment(AppModel.self) private var model
    let agent: Agent

    var body: some View {
        let pinned = model.isPinned(agent)
        Button(pinned ? "Unpin" : "Pin", systemImage: pinned ? "pin.slash" : "pin") {
            Task { await model.setPinned(agent, !pinned) }
        }
        .help(pinned ? "Put this session back among the others"
                     : "Keep this session at the top of its project, whatever its state")
    }
}
