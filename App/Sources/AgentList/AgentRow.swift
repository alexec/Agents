import AgentsKitCore
import SwiftUI

/// One agent on a folder page: what it is, and what it is doing.
///
/// An icon for the state, the name it was given, and a line saying what it is working
/// on. The name is what it was asked; the line under it is what is happening now, which
/// is the thing you came to find out.
struct AgentRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    /// The agent as the list had it when it drew this row. Only its id is trusted.
    private let given: Agent
    /// A row of the Mac's sessions list rather than a card on a page: a list-sized
    /// title and one line of what it said, so a column of them reads at a glance.
    private let isCompact: Bool
    /// Which folder it is in, after the title: under a smart row of the sidebar (#495),
    /// which gathers sessions from every folder, and nowhere else.
    private let place: String?
    /// Where it sits in the sidebar's tree (#835): a parent with its count and fold, or a
    /// child one indent in. Nil off the sidebar.
    private let tree: SidebarTree.Row?
    /// Folds or unfolds a parent's children.
    private let toggleFold: () -> Void

    init(agent: Agent, isCompact: Bool = false, place: String? = nil,
         tree: SidebarTree.Row? = nil, toggleFold: @escaping () -> Void = {}) {
        given = agent
        self.isCompact = isCompact
        self.place = place
        self.tree = tree
        self.toggleFold = toggleFold
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
            if isCompact, agent.state == .archived {
                Image(systemName: "archivebox")
                    .glyph(size: 13)
                    .sidebarMark(.secondary)
                    .frame(width: 16)
                    .padding(.top, 1)
                    .accessibilityLabel("Archived")
            } else if isCompact, let mark = SessionMark(agent: markAgent, group: model.work.group(of: markAgent)) {
                mark.padding(.top, 1)
            } else {
            StatusIcon(state: agent.state, isComingBack: isComingBack,
                       outcome: agent.report?.outcome,
                       isWaiting: agent.isWaiting,
                       isUnaccountedFor: agent.endingIsUnaccountedFor,
                       ending: agent.endedReason?.summary,
                       endedReason: agent.endedReason,
                       isUnread: agent.isUnread,
                       isWaitingForPerson: agent.isWaitingForPerson,
                       personLine: agent.eventWait?.personLine,
                       tool: RunningToolWords.tool(agent))
                .frame(width: isCompact ? 16 : nil)
                .padding(.top, 1)
            }

            VStack(alignment: .leading, spacing: isCompact ? 4 : 3) {
                HStack(spacing: 5) {
                    // Unread is a mark on the row, as in Mail, and never a group (#70): a
                    // dot and a heavier title, both gone once it is opened, and the row
                    // where it was. Said as the title's value, not as a label over the
                    // row, which would stack on the Text's own (one element per row).
                    // In the sidebar the bold title alone says unread (#1323); the dot is the page's.
                    if agent.drawsUnread, !isCompact {
                        UnreadDot()
                    }
                    if model.renaming == Renaming(id: agent.id) {
                        // Edited in place (#751), as Finder renames a file.
                        RenameField(agent: agent)
                            .appText(isCompact ? .supporting : .reading)
                    } else {
                    // The folder's name whole up to 40% of the line, then cut, so a long
                    // one never pushes the title out (#936).
                    TitleAndPlace {
                        Text(agent.title ?? "Untitled")
                            .appText(isCompact ? .supporting : .reading)
                            .fontWeight(agent.drawsUnread ? .semibold : .regular)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .accessibilityValue(agent.drawsUnread ? "unread" : "")
                        if let place {
                            Text(place)
                                .appText(.fine)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }
                    }
                    // Started by a workflow rather than a person: the one thing about
                    // an agent's origin worth a mark, because it is the difference
                    // between something you asked for and something that ran itself.
                    if let workflowName = startedByWorkflowName {
                        Image(systemName: "flowchart")
                            .appText(.fine)
                            .sidebarMark(.tertiary)
                            .help("Started by the workflow \(workflowName)")
                            .accessibilityLabel("started by the workflow \(workflowName)")
                    }
                    // Mute Notifications (#2003): a bell with a slash, as Messages marks it.
                    if agent.isMuted {
                        Image(systemName: MuteWords.symbol)
                            .appText(.fine)
                            .sidebarMark(.tertiary)
                            .help(MuteWords.mutedHelp)
                            .accessibilityLabel(MuteWords.muted)
                    }
                    // Voice mode listens in this chat (#2518): beside the mute mark, and
                    // gone the moment voice mode ends.
                    if VoiceMode.shared.isOn(in: agent.id) {
                        ListeningMark()
                    }
                    // Started by another agent (028): the same kind of mark, for the
                    // same reason — this is not something the person typed for.
                    if let starter = model.startedByAgentLabel(agent) {
                        Image(systemName: AgentsModel.startedByAgentSymbol)
                            .appText(.fine)
                            .sidebarMark(.tertiary)
                            .help(starter)
                            .accessibilityLabel(starter)
                    }
                    // A file it showed that the person has not looked at (#1802): ending 2,
                    // "I have something for you", a mark and never Needs you.
                    if let file = FileToSeeWords.line(agent) {
                        Image(systemName: FileToSeeWords.symbol)
                            .appText(.fine)
                            .sidebarMark(.secondary)
                            .help(file)
                            .accessibilityLabel(file)
                    }
                }

                // The agent's own account of its last turn, and nothing else. This line
                // used to be whichever of five things was true — a plan step, the
                // report, "Waiting for your answer", why it stopped — with the runtime
                // and a step count under it, and a row that says a different kind of
                // thing depending on state is a row nobody can read at a glance. The
                // state is the icon's; what it is doing is the title, which the agent
                // keeps current; this is what it said.
                // Stop or archive on its way, from whichever control sent it (#87).
                // In the report's place, at the report line's height. Nothing is held for
                // the line when there is none (#144): the row is fixed to its height below,
                // so the list measures it again when a line arrives.
                if let acting = model.acting(agent.id) {
                    Telling(host: model.answerRecipient(agent.id), doing: acting.doing)
                        .frame(height: isCompact ? 14 : nil)
                } else if let queued = model.queuedLine(agent) {
                    // Its place in its folder's queue (#362), in the report's place: it
                    // has said nothing yet, and starts by itself when a place frees.
                    Text(queued)
                        .appText(isCompact ? .fine : .supporting)
                        .foregroundStyle(.secondary)
                        .help("Starts by itself when this folder has a place free for another helper")
                } else if let reason = needsYouLine {
                    Text(reason)
                        .appText(isCompact ? .fine : .supporting)
                        .foregroundStyle(.secondary)
                        .lineLimit(isCompact ? 1 : 2)
                        .fixedSize(horizontal: false, vertical: true)
                } else if agent.missingFolder != nil, agent.state != .archived {
                    // Its folder gone (#119): said before anybody types, as a folder's
                    // row says it, in the report's place.
                    Text(MissingFolderWords.label)
                        .appText(isCompact ? .fine : .supporting)
                        .foregroundStyle(.secondary)
                        .help(agent.folderGoneMessage)
                } else if isCompact, let said = model.work.saidLines[agent.id] {
                    // While the sidebar searches: the line it said that matches, in the
                    // report's place, so a row found by what it said says why (#1663).
                    // The page's row has it on a line of its own, below.
                    Text(said)
                        .appText(.fine)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(said)
                } else if let report = FileToSeeWords.reportLine(agent) {
                    // Grey under the white title, in the sidebar as on the page (#587); a
                    // file to see is named here first (#1873).
                    Text(report)
                        .appText(isCompact ? .fine : .supporting)
                        .foregroundStyle(.secondary)
                        .lineLimit(isCompact ? 1 : 2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // In the sidebar the row is the title and that one line (#587): what it
                // holds, waits on, runs or is labelled with is the chat's to say, where
                // the prompt bar and the wait lines carry it, and Carry on with it.
                if !isCompact {
                    // Working in a worktree (030): named, because with two agents in one
                    // folder the worktree is how you tell whose changes are whose. On this
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

                    // What it holds (036), so an idle agent still holding the simulator can be
                    // seen from the list. What it waits for is the wait line's.
                    if let leases = model.work.leaseStatus(of: agent.id)?.holdingOnly {
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

                    // What it waits for (#582): agents (039), events (042) and resources (036)
                    // on one line, the first and how many more, so the row says what it is
                    // waiting for without opening it (039 SC-005) and stays one line tall.
                    // Each in full is the line's help, and the chat's; Carry on is the menu's.
                    if let wait = model.work.waitMark(of: agent) {
                        Text(wait.line)
                            .appText(.fine)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .help(wait.detail)
                    }
                    // While the sidebar searches: the line it said that matches (#1585).
                    if let said = model.work.saidLines[agent.id] {
                        Text(said)
                            .appText(.fine)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .help(said)
                    }
                    // An agent asked for it to be archived (#584): the mark, and the one
                    // click that agrees. In the sidebar the leading mark says it instead.
                    if let line = ArchiveRequestWords.line(agent) {
                        HStack(spacing: 6) {
                            Label(line, systemImage: ArchiveRequestWords.symbol)
                                .appText(.fine)
                                .foregroundStyle(.secondary)
                            Button(ArchiveRequestWords.archive) {
                                Task { await model.archive(agent.id, andLeave: true) }
                            }
                            .buttonStyle(.paper)
                            .controlSize(.small)
                            .help(ArchiveRequestWords.archiveHelp)
                            .disabled(isActing)
                        }
                        .padding(.top, 3)
                    }
                }
            }
            Spacer(minLength: 0)
            if let tree, tree.children > 0 {
                FoldCount(count: tree.children, isUnfolded: tree.isUnfolded, toggle: toggleFold)
                    .padding(.top, 1)
            }
            // When it last did anything, as the page's row has it (#341).
            ActivityTime(date: agent.lastActivityAt)
                .padding(.top, 1)
        }
        // A child one indent in, under the mark's column (#835).
        .padding(.leading, tree?.isChild == true ? 22 : 0)
        .fixedSize(horizontal: false, vertical: true)
        .contextMenu {
            // Beside the main window or on another screen (#826).
            Button("Open in New Window") { openWindow(id: MainWindow.poppedSceneID, value: agent.id) }
            Divider()
            if model.isBlocked(agent) {
                Button(AgentsModel.carryOnLabel) { Task { await model.carryOn(agent.id) } }
            }
            if model.canStop(agent) {
                Button("Stop") { Task { await model.stop(agent.id) } }
                    .disabled(isActing)
            }
            // The sessions it started too (#835).
            if agent.state != .archived, model.work.liveDescendants(of: agent.id).contains(where: model.canStop) {
                Button("Stop All") { Task { await model.stopAll(agent.id) } }
                    .disabled(isActing)
            }
            if agent.state == .archived {
                Button("Unarchive") { Task { await model.unarchive(agent.id) } }
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
                // No push, banner or Mac notification, and still in Needs You (#2003).
                if model.canMute(agent) {
                    Button(MuteWords.label(muted: agent.isMuted), systemImage: MuteWords.symbol(muted: agent.isMuted)) {
                        Task { await model.setMuted(agent.id, !agent.isMuted) }
                    }
                    .help(MuteWords.help(muted: agent.isMuted))
                }
                // The person's title, which the runtime's no longer replaces (#751).
                Button("Rename…") { model.renaming = Renaming(id: agent.id) }
                // At the top of its folder whatever its state, or back among the rest (#180).
                PinSessionButton(agent: agent)
                // Branching leaves the original alone and carries the history so far.
                Button("Branch") { Task { await model.fork(agent.id) } }
                Button("Archive") { Task { await model.archive(agent.id, andLeave: true) } }
                    .disabled(isActing)
                // Deny an agent's ask to be archived (#773): the session stays.
                if agent.asksToArchive {
                    Button(ArchiveRequestWords.keep) { Task { await model.keepSession(agent) } }
                        .disabled(isActing)
                }
            }
            Divider()
            // Its record and transcript as a .tar.gz, to keep or import elsewhere (#1001).
            Button("Export…") { Task { await model.exportAgent(agent) } }
                .disabled(model.hostUnreachable(agent.host) || model.exportImport != nil)
            // Finder only sees this Mac's disk (058, FR-019).
            if model.isOnThisMac(agent.host) {
                Button("Show in Finder") {
                    model.reveal(agent.cwd, on: agent.host)
                }
            }
        }
    }

    /// What the session asked, or why it stopped, while this row needs a person.
    private var needsYouLine: String? {
        let question = model.work.permission(for: agent.id)?.toolCall.line
            ?? model.work.elicitation(for: agent.id)?.message
            ?? model.work.elicitation(for: agent.id)?.title
        return StatusShape.needsYouLine(row: agent, isComingBack: isComingBack, question: question)
    }

    /// The session whose mark the row shows: its own, or for a folded parent the most
    /// urgent of it and the sessions it started (#835).
    private var markAgent: Agent {
        guard let tree, tree.children > 0, !tree.isUnfolded else { return agent }
        return SidebarTree.markAgent(of: agent, in: model.work)
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
        return model.workflows(in: agent.folderPath).first { $0.workflow.workflowID == id }?.workflow.name ?? id
    }
}

/// A parent's count of the sessions under it and its fold (#835), at the row's end before
/// the time.
private struct FoldCount: View {
    let count: Int
    let isUnfolded: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 3) {
                Text("\(count)")
                Image(systemName: "chevron.right")
                    .rotationEffect(.degrees(isUnfolded ? 90 : 0))
            }
            .appText(.fine)
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isUnfolded ? "Hide the sessions it started" : "Show the \(count) sessions it started")
        // One element with one label: a label over the Text's own crashes AppKit.
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { toggle() }
        .accessibilityLabel(isUnfolded ? "Hide \(count) started sessions" : "Show \(count) started sessions")
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
/// orange hand when it needs the person, a spinner in the accent while it works (#1558),
/// a tick once done, read or not (#1323, #2363); a numbered list while queued, a breathing
/// beacon while it waits (#2456, #2657) and a pause mark once stopped (#630).
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
        // Asking to be archived (#584) is what the person has left to do with it.
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
    /// On a row filled with the accent, the ring is the ground as the other marks (#2382).
    @Environment(\.drawsOnAccent) private var onAccent

    var body: some View {
        Group {
            switch kind {
            case .needsYou:
                Image(systemName: "hand.raised.fill").sidebarMark(StateTint.attention.style(or: .secondary))
            case .working:
                // In the accent as the other marks, and in step with every one (#1558, #2044).
                // One case for both activities, so a tool tips the same ring (#2332).
                WorkingRing(size: 12 * scale, color: onAccent ? Paper.ground : Paper.accent, doing: tool != nil)
            case .queued:
                Image(systemName: "list.number").sidebarMark(Paper.accent)
            case .waiting:
                // The waiting card's beacon, breathing in step with every other (#2456, #2657).
                WaitingBeacon(size: 12 * scale, color: onAccent ? Paper.ground : Paper.accent)
            case .paused:
                Image(systemName: "pause.circle").sidebarMark(Paper.accent)
            case .done:
                Image(systemName: "checkmark").sidebarMark(Paper.accent)
            case .asksToArchive:
                Image(systemName: ArchiveRequestWords.symbol).sidebarMark(StateTint.attention.style(or: .secondary))
            }
        }
        .frame(width: 16 * scale, height: 16 * scale)
        // The tool by name on the pointer (#1902); the other marks say theirs in the row.
        .help(kind == .needsYou ? StatusShape.words(row: agent, isComingBack: false)
            : tool.map(RunningToolWords.label) ?? "")
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
    /// Waiting for an allowance to come back (052, US4): it will carry on by itself, so
    /// it does not want a person, whatever its stopped shape says.
    var isWaitingForAllowance = false
    /// Only the connected person can carry this on (`Agent.isWaitingForPerson`, #3051).
    var isWaitingForPerson = false
    /// What that wait asks of them, said in place of Finished (`EventWait.personLine`, #3147).
    var personLine: String?
    /// The tool it runs, which tips the working ring (#2044, #2332).
    var tool: String?
    /// The well grows with the text beside it (#750), so the row keeps its shape.
    @ScaledMetric private var scale: CGFloat = 1
    /// On a row filled with the accent, the dot is the ground as the other marks (#2382).
    @Environment(\.drawsOnAccent) private var onAccent

    private var shape: StatusShape {
        StatusShape(state: state, outcome: outcome, isWaiting: isWaiting, isComingBack: isComingBack,
                    endedReason: endedReason,
                    waitingForAllowance: isWaitingForAllowance,
                    outcomeUnknown: isUnaccountedFor,
                    waitingForPerson: isWaitingForPerson)
    }

    var body: some View {
        Group {
            if shape == .waiting {
                // The beacon breathes in the accent, where the unread dot before the title is grey,
                // round and still (#2456, #2657).
                WaitingBeacon(size: 12 * scale, color: onAccent ? Paper.ground : Paper.accent)
            } else if let symbol = shape.symbol {
                Image(systemName: symbol)
                    // Decorative: a glyph filling an 18-point well, not text (FR-015).
                    .glyph(size: 15)
                    .sidebarMark((StatusShape.isTinted(shape, isWaitingForAllowance: isWaitingForAllowance)
                                  ? StateTint.attention : .none)
                        .style(or: .secondary))
            } else {
                WorkingRing(size: 12 * scale, doing: tool != nil)
            }
        }
        .frame(width: 18 * scale, height: 18 * scale)
        .help(description)
        .accessibilityLabel(description)
    }

    /// What a screen reader hears, and what the tooltip says: `StatusShape.words`, which
    /// the web remote says too. A running tool is named, as the tipping ring draws it (#2261).
    private var description: String {
        StatusShape.words(shape, state: state, isComingBack: isComingBack, outcome: outcome,
                          isUnaccountedFor: isUnaccountedFor, ending: ending, isUnread: isUnread,
                          isWaitingForAllowance: isWaitingForAllowance, tool: tool, personLine: personLine)
    }
}

/// The unread mark before a row's title (#70). Grey, not the attention colour: unread
/// is news, not a need. Silent to a screen reader, which hears the title's value instead.
struct UnreadDot: View {
    @ScaledMetric private var scale: CGFloat = 1

    var body: some View {
        Circle()
            .fill(.secondary)
            .frame(width: 7 * scale, height: 7 * scale)
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
                     : "Keep this session at the top of its folder, whatever its state")
    }
}
