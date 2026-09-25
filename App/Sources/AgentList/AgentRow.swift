import AgentsKit
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

    init(agent: Agent) {
        given = agent
    }

    /// The agent as the window has it now, read from the model rather than kept.
    ///
    /// A row that drew the copy it was handed stayed on that copy: a card that moved
    /// between groups in the lazy stack kept its first render, so a finished agent sat
    /// under Complete with a spinner and its first title, and one prompted again sat
    /// under Working with a tick. The heading was right, because it is counted from the
    /// model; the row was not, because nothing made the stack hand it the new copy.
    /// Reading the model here makes this row observe the agent itself.
    private var agent: Agent { model.agents.first { $0.id == given.id } ?? given }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            StatusIcon(state: agent.state, isComingBack: isComingBack,
                       outcome: agent.report?.outcome,
                       isUnaccountedFor: agent.endingIsUnaccountedFor,
                       ending: agent.endedReason?.summary,
                       isParked: agent.parking?.isParked == true)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(agent.title ?? "Untitled")
                        .appText(.reading).fontWeight(.semibold)
                        .lineLimit(1)
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
                    // Working in a worktree (030): named, because with two agents in
                    // one project the worktree is how you tell whose changes are whose.
                    if let worktree = agent.worktree {
                        WorktreeBadge(worktree: worktree, isGone: !worktreeIsThere(worktree))
                    }
                }

                // The agent's own account of its last turn, and nothing else. This line
                // used to be whichever of five things was true — a plan step, the
                // report, "Waiting for your answer", why it stopped — with the runtime
                // and a step count under it, and a row that says a different kind of
                // thing depending on state is a row nobody can read at a glance. The
                // state is the icon's; what it is doing is the title, which the agent
                // keeps current; this is what it said.
                if let report = agent.report?.message {
                    Text(report)
                        .appText(.supporting)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // What it holds or waits for (036), so an idle agent still holding the
                // simulator can be seen from the list.
                if let leases = model.work.leaseStatus(of: agent.id) {
                    LeaseMark(status: leases)
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
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .padding(.top, 3)
                        .help("Tell it the block has cleared, and let it carry on")
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
        }
        .contextMenu {
            if model.isBlocked(agent) {
                Button(AgentsModel.carryOnLabel) { Task { await model.carryOn(agent.id) } }
            }
            if model.canStop(agent) {
                Button("Stop") { Task { await model.stop(agent.id) } }
            }
            if agent.state == .archived {
                Button("Bring back") { Task { await model.unarchive(agent.id) } }
            } else {
                // Branching leaves the original alone and carries the history so far.
                Button("Branch") { Task { await model.fork(agent.id) } }
                if let action = agent.parkAction {
                    Button(ParkWords.label(action), systemImage: ParkWords.symbol(action)) {
                        Task { await model.perform(action, on: agent.id) }
                    }
                    .help(ParkWords.help(action))
                }
                Button("Archive") { Task { await model.archive(agent.id) } }
            }
            Divider()
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([agent.cwd])
            }
        }
    }

    private func worktreeIsThere(_ worktree: AgentWorktree) -> Bool {
        FileManager.default.fileExists(atPath: worktree.root.path(percentEncoded: false))
    }

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
struct StatusIcon: View {
    let state: AgentState
    /// The daemon is bringing this chat back by itself after a restart.
    var isComingBack = false
    /// What the agent said about the work, where it said anything.
    var outcome: WorkOutcome?
    /// A turn that ended cleanly, was asked how it went, and still said nothing.
    var isUnaccountedFor = false
    /// Why it stopped, where it did, in `EndedReason`'s words.
    var ending: String?
    /// Parked (040): the shape still says how it ended, but it is not orange, because
    /// the person has seen it and chosen later.
    var isParked = false

    private var shape: StatusShape {
        StatusShape(state: state, outcome: outcome, isComingBack: isComingBack)
    }

    var body: some View {
        Group {
            if let symbol = shape.symbol {
                Image(systemName: symbol)
                    // Decorative: a glyph filling an 18-point well, not text (FR-015).
                    .font(.system(size: 15))
                    .foregroundStyle((shape.wantsAPerson && !isParked ? StateTint.attention : .none)
                        .style(or: .secondary))
            } else {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
            }
        }
        .frame(width: 18, height: 18)
        .help(description)
        .accessibilityLabel(description)
    }

    /// The outcome, where the turn it describes is the one the agent is settled on.
    private var settledOutcome: WorkOutcome? {
        state == .finished && !isComingBack ? outcome : nil
    }

    /// What a screen reader hears, and what the tooltip says. Precise where the shape
    /// is not: the outcome's words come from `WorkOutcome.heading`, which the phone
    /// reads too, and a stopped agent says why.
    private var description: String {
        if isComingBack { return AgentsModel.comingBackDescription }
        if let settledOutcome { return settledOutcome.heading }
        if isUnaccountedFor && state == .finished { return "Finished without saying how it went" }
        switch state {
        case .running: return "Working"
        case .starting: return AgentState.startingLabel
        case .waitingOnUser: return "Waiting on you"
        case .finished: return "Finished"
        case .stopped: return ending ?? "Stopped"
        case .archived: return "Archived"
        }
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
