import AgentsKitCore
import SwiftUI

struct RemoteSessionLabels: View {
    @Environment(RemoteModel.self) private var model
    let agent: Agent
    let compact: Bool
    @State private var adding = false
    @State private var draft = ""

    var body: some View {
        Group {
            if compact {
                RemoteCompactLabelRow(labels: agent.labels)
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(agent.labels, id: \.normalizedValue) { label in
                        RemoteLabelChip(label: label)
                    }
                    Menu {
                        ForEach(agent.labels, id: \.normalizedValue) { label in
                            Button("Remove \(label.value)") {
                                Task { _ = await model.setLabels(on: agent.id, remove: [label.value]) }
                            }
                        }
                        if agent.labels.count < SessionLabelPolicy.maximumCount {
                            ForEach(suggestions, id: \.self) { value in
                                Button(value) { Task { _ = await model.setLabels(on: agent.id, add: [value]) } }
                            }
                            Button("New label…") { adding = true }
                        }
                    } label: {
                        Label("Edit labels", systemImage: "tag")
                    }
                }
            }
        }
        .alert("Add label", isPresented: $adding) {
            TextField("Label", text: $draft)
            Button("Add") {
                let value = draft
                draft = ""
                Task { _ = await model.setLabels(on: agent.id, add: [value]) }
            }
            Button("Cancel", role: .cancel) { draft = "" }
        } message: {
            Text("Use 1–24 characters. A session can have up to five labels.")
        }
    }

    private var suggestions: [String] {
        let existing = Set(agent.labels.map(\.normalizedValue))
        return model.labelSuggestions(in: agent.projectFolder)
            .filter { !existing.contains(SessionLabelPolicy.key($0)) }
    }
}

private struct RemoteLabelChip: View {
    let label: SessionLabel

    var body: some View {
        Text(label.value)
            .appText(.fine)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(label.owner == .person ? Color.accentColor.opacity(0.15) : Color.clear)
            .clipShape(Capsule())
            .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.5)))
            .accessibilityLabel("\(label.value), \(label.owner.rawValue) label")
    }
}

private struct RemoteCompactLabelRow: View {
    let labels: [SessionLabel]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 5) {
                ForEach(labels.prefix(2), id: \.normalizedValue) { label in
                    RemoteLabelChip(label: label)
                }
                if labels.count > 2 { count(labels.count - 2) }
            }
            HStack(spacing: 5) {
                if let first = labels.first { RemoteLabelChip(label: first) }
                if labels.count > 1 { count(labels.count - 1) }
            }
        }
    }

    private func count(_ amount: Int) -> some View {
        Text("+\(amount)")
            .appText(.fine)
            .accessibilityLabel("\(amount) more labels")
    }
}

/// One agent, as a card you can go into.
///
/// The whole card is the control, which is why it is a paper row rather than a
/// line of text — and what makes it a target a thumb can hit without aiming.
struct AgentCard: View {
    @Environment(RemoteModel.self) private var model
    @State private var addingLabel = false
    @State private var labelDraft = ""
    /// The agent as the list had it when it drew this card. Only its id is trusted.
    private let given: Agent

    init(agent: Agent) {
        given = agent
    }

    /// The agent as the phone has it now, read from the model rather than kept. A card
    /// that drew the copy it was handed kept its first render when it moved between
    /// groups in the lazy stack — the Mac's row did exactly that; see `AgentRow`.
    private var agent: Agent { model.work.agent(given.id) ?? given }

    var body: some View {
        NavigationLink(value: RemoteRoute.agent(agent.id)) {
            HStack(alignment: .top, spacing: 12) {
                StatusIcon(state: agent.state, isComingBack: isComingBack,
                           outcome: agent.report?.outcome,
                           isWaiting: agent.isWaiting,
                           isUnread: agent.isUnread,
                           endedReason: agent.endedReason,
                           outcomeUnknown: agent.endingIsUnaccountedFor,
                           isParked: agent.parking?.isParked == true)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(agent.title ?? "Untitled")
                            .appText(.reading).fontWeight(.semibold)
                            .lineLimit(2)
                        // Started by another agent (028), marked as the Mac's row
                        // marks it.
                        if model.startedByAgentLabel(agent) != nil {
                            Image(systemName: AgentsModel.startedByAgentSymbol)
                                .appText(.fine)
                                .foregroundStyle(.tertiary)
                        }
                        // Working in a worktree (030), named as on the Mac's row. The
                        // phone cannot see the Mac's disk, so a worktree that has gone
                        // is not marked here.
                        if let worktree = agent.worktree {
                            HStack(spacing: 3) {
                                Image(systemName: "arrow.triangle.branch")
                                Text(worktree.name).lineLimit(1)
                            }
                            .appText(.fine)
                            .foregroundStyle(.tertiary)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("in worktree \(worktree.name)")
                        }
                    }

                    // The agent's own account of its last turn, and nothing else — the
                    // same two lines as the Mac's row. The state is the icon's; what it
                    // is doing is the title, which the agent keeps current.
                    if let report = agent.report?.message {
                        Text(report)
                            .appText(.supporting)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !agent.labels.isEmpty {
                        RemoteSessionLabels(agent: agent, compact: true)
                    }
                    // When it will be retired, or why it is kept, in the Mac row's
                    // words (051). The phone has no settings, so the cap goes unnamed.
                    if agent.state == .archived,
                       let note = RetirementWords.rowNote(agent.retirement, now: Date(),
                                                          cap: model.work.retentionState?.settings.cap) {
                        Text(note)
                            .appText(.fine)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    // What it holds or waits for, in the Mac row's words (036).
                    if let leases = model.work.leaseStatus(of: agent.id) {
                        LeaseMark(status: leases)
                    }
                    // Waiting on events (042), as the Mac's row says it.
                    if agent.eventWait?.isOpen == true, let wait = model.work.waitStatus(of: agent) {
                        Text(wait.mark)
                            .appText(.fine)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    // Blocked (039): what it waits on and when it looks again, in the
                    // Mac row's words. Carry on is in the card's menu and the chat, not
                    // here: the whole card is the one control (see `AgentRow`).
                    ForEach(model.blockLines(agent), id: \.self) { line in
                        Text(line)
                            .appText(.fine)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    // As on the Mac's row (040).
                    if let line = ParkWords.line(agent.parking) {
                        Text(line)
                            .appText(.fine)
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 14))
            .paperRow()
        }
        .buttonStyle(.plain)
        .contextMenu {
            Menu("Labels") {
                ForEach(agent.labels, id: \.normalizedValue) { label in
                    Button("Remove \(label.value)") {
                        Task { _ = await model.setLabels(on: agent.id, remove: [label.value]) }
                    }
                }
                if agent.labels.count < SessionLabelPolicy.maximumCount {
                    let used = Set(agent.labels.map(\.normalizedValue))
                    ForEach(model.labelSuggestions(in: agent.projectFolder)
                        .filter { !used.contains(SessionLabelPolicy.key($0)) }, id: \.self) { value in
                        Button("Add \(value)") {
                            Task { _ = await model.setLabels(on: agent.id, add: [value]) }
                        }
                    }
                    Button("New label…") { addingLabel = true }
                }
            }
            if model.isBlocked(agent) {
                Button {
                    Task { await model.carryOn(agent.id) }
                } label: {
                    Label(AgentsModel.carryOnLabel, systemImage: "play.circle")
                }
                .help(AgentsModel.carryOnHelp(for: agent))
            }
            // Here rather than over the chat, as on the Mac: the chat is for reading.
            if let action = agent.parkAction {
                Button {
                    Task { await model.perform(action, on: agent.id) }
                } label: {
                    Label(ParkWords.label(action), systemImage: ParkWords.symbol(action))
                }
                .disabled(model.isStale)
                .accessibilityHint(ParkWords.help(action, isMarkedOnly: agent.parking?.isParked == false))
            }
            if agent.state != .archived {
                archiveButton
            }
        }
        .alert("Add label", isPresented: $addingLabel) {
            TextField("Label", text: $labelDraft)
            Button("Add") {
                let value = labelDraft
                labelDraft = ""
                Task { _ = await model.setLabels(on: agent.id, add: [value]) }
            }
            Button("Cancel", role: .cancel) { labelDraft = "" }
        }
        // As a row in Mail: a swipe uncovers Archive, and a long one archives. The page
        // is a `swipeActionsContainer`.
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            if agent.state != .archived {
                archiveButton.tint(.gray)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var archiveButton: some View {
        Button {
            Task { await model.archive(agent.id) }
        } label: {
            Label("Archive", systemImage: "archivebox")
        }
        .disabled(model.isStale)
    }

    /// Whether the Mac is bringing this chat back by itself after a restart.
    private var isComingBack: Bool { model.isComingBack(agent) }

    /// The state said in words, because the icon beside it is not one VoiceOver reads.
    /// Precise where the shape is not: which outcome, and why it stopped.
    private var accessibilityLabel: String {
        var words = isComingBack
            ? AgentsModel.comingBackDescription
            : StatusIcon.words(for: agent.state, outcome: agent.report?.outcome,
                               isWaiting: agent.isWaiting,
                               isUnread: agent.isUnread,
                               isUnaccountedFor: agent.endingIsUnaccountedFor)
        if agent.state == .stopped, let why = agent.endedReason?.summary { words = why }
        return ([agent.title ?? "Untitled", model.startedByAgentLabel(agent), words, agent.report?.message]
            .compactMap { $0 } + model.blockLines(agent) + [ParkWords.line(agent.parking)].compactMap { $0 })
            .joined(separator: ", ")
    }
}

/// What state an agent is in, as one of four shapes.
///
/// The shape is `StatusShape`'s, which the Mac's row draws from too, so the two cannot
/// disagree about it. Grey, all of it, except the one that wants you.
struct StatusIcon: View {
    let state: AgentState
    /// The Mac is bringing this chat back by itself after a restart.
    var isComingBack = false
    /// What the agent said about the work, where it said anything.
    var outcome: WorkOutcome?
    /// The app will carry it on by itself (`Agent.isWaiting`): Waiting, not Blocked.
    var isWaiting = false
    var isUnread = false
    var endedReason: EndedReason?
    var outcomeUnknown = false
    var isWaitingForAllowance = false
    /// Parked (040): the shape, but not orange. See the Mac's `StatusIcon`.
    var isParked = false

    private var shape: StatusShape {
        StatusShape(state: state, outcome: outcome, isWaiting: isWaiting, isComingBack: isComingBack,
                    isUnread: isUnread, endedReason: endedReason,
                    waitingForAllowance: isWaitingForAllowance,
                    outcomeUnknown: outcomeUnknown)
    }

    var body: some View {
        Group {
            if let symbol = shape.symbol {
                Image(systemName: symbol)
                    // Decorative: a glyph filling a 20-point well, not text (FR-015).
                    .font(.system(size: 16))
                    .foregroundStyle((shape.wantsAPerson && !isParked ? StateTint.attention : .none)
                        .style(or: .secondary))
            } else {
                SyncedSpinner(diameter: 18)
            }
        }
        .frame(width: 20, height: 20)
        .accessibilityHidden(true)
    }

    /// The words a screen reader hears. An outcome's come from `WorkOutcome.heading`,
    /// which is the same place the Mac reads them, so the two cannot drift (FR-017).
    static func words(for state: AgentState, outcome: WorkOutcome? = nil, isWaiting: Bool = false,
                      isUnread: Bool = false, isUnaccountedFor: Bool = false) -> String {
        if state == .finished && isUnread { return "Unread · \(outcome?.heading ?? "Finished")" }
        if StatusShape(state: state, outcome: outcome, isWaiting: isWaiting, isComingBack: false) == .waiting {
            return StatusShape.waitingLabel
        }
        if state == .finished, let outcome { return outcome.heading }
        if state == .finished, isUnaccountedFor { return "Finished without saying how it went" }
        switch state {
        case .running: return "Working"
        case .starting: return AgentState.startingLabel
        case .waitingOnUser: return "Waiting on you"
        case .finished: return "Finished"
        case .stopped: return "Stopped"
        case .archived: return "Archived"
        }
    }
}
