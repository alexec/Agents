import AgentsKitCore
import SwiftUI

/// What agents take turns with on a machine, who holds each and who is waiting (036 US3,
/// US4), as a section of the machine's page (#3629). It was Status ▸ Resources, which was
/// this Mac's only.
///
/// What the person can do here is two things: end a lease, and take an agent out of a
/// line. There is no way to take one. Only agents hold leases, and they take them
/// themselves when they need them (spec, Clarifications). A free resource therefore has
/// no button at all.
///
/// Nothing is tinted. Holding an agreement is not a person being needed, a failure,
/// or a vouched completion, which are the only things colour means here. The web page
/// draws the same in Web/src/views/Resources.tsx.
struct MachineResourcesSection: View {
    @Environment(AppModel.self) private var model
    let host: MachineRef

    /// Groups whose free rows are all showing. A Mac with Xcode has twenty-odd
    /// simulators, and a section that lists every free one pushes the rest below the
    /// fold for no reason: what anyone comes here to see is what is held.
    @State private var unfolded: Set<String> = []
    private static let freeShown = 4

    /// The id of the section's first row, for the Go menu's Resources to scroll to.
    static let top = "machine-resources"

    private var snapshot: DaemonAPI.LeaseSnapshot? { model.leases(on: host) }

    /// The section's groups, always in this order. A group with nothing in it is not
    /// drawn: a Mac without Xcode has no simulators, and names only exist while leased.
    /// Declared ones come first, free or held, with what each is for (#116).
    private var groups: [(title: String, rows: [DaemonAPI.ResourceState])] {
        let resources = snapshot?.resources ?? []
        return ([("Declared", resources.filter { $0.declared != nil })]
            + [("Screen", ResourceKind.screen), ("Simulators", .simulator), ("Browsers", .browser),
               ("Named by agents", .named)]
            .map { title, kind in (title, resources.filter { $0.kind == kind && $0.declared == nil }) })
            .filter { !$0.rows.isEmpty }
    }

    /// Whether the section is drawn (#3743): only when a resource is declared, held or
    /// awaited. Free simulators and browsers alone are not news.
    private var shows: Bool {
        (snapshot?.resources ?? []).contains { $0.declared != nil || !$0.holds.isEmpty || !$0.line.isEmpty }
    }

    var body: some View {
        if shows { section }
    }

    /// The machine's leases, read while its page is open: by the page, as the section may not
    /// be drawn. This Mac's arrive as they change; another machine's are read every few seconds.
    static func read(_ model: AppModel, on host: MachineRef) async {
        await model.refreshLeases(on: host)
        guard host != .mac else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(5))
            await model.refreshLeases(on: host)
        }
    }

    private var section: some View {
        Section {
            ForEach(Array(groups.enumerated()), id: \.element.title) { index, group in
                Text(group.title.uppercased())
                    .appText(.fine).fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .id(index == 0 ? Self.top : group.title)
                let (shown, folded) = fold(group.rows, group: group.title)
                ForEach(shown) { state in
                    ResourceRow(host: host, state: state, at: snapshot?.at ?? Date())
                        .id(state.name)
                }
                if folded > 0 {
                    Button("Show \(folded) more free") { unfolded.insert(group.title) }
                        .buttonStyle(.plain)
                        .appText(.fine)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            HStack(alignment: .firstTextBaseline) {
                Text("Resources")
                    .help("Things on this machine that agents take turns with. A lease is an agreement between agents, not a lock.")
                Spacer()
                if host == .mac {
                    SettingsLink { Text("Declare in Settings\u{2026}") }
                        .simultaneousGesture(TapGesture().onEnded { model.settingsPaneAsked = .resources })
                        .appText(.fine)
                }
            }
        }
    }

    /// Every held or awaited row, and the first few free ones unless the group has been
    /// unfolded. The rest are counted, not hidden without a word.
    private func fold(_ rows: [DaemonAPI.ResourceState], group: String) -> (shown: [DaemonAPI.ResourceState], folded: Int) {
        // Declared ones are few, and the person put each there: never folded.
        guard group != "Declared", !unfolded.contains(group) else { return (rows, 0) }
        var freeSoFar = 0
        let asked = model.resourcesAsked?.name
        let shown = rows.filter { state in
            if !state.holds.isEmpty || !state.line.isEmpty || state.name == asked { return true }
            freeSoFar += 1
            return freeSoFar <= Self.freeShown
        }
        return (shown, rows.count - shown.count)
    }
}

/// What a chat's capsule or the Go menu asked This Mac's page to show (#3629): one resource,
/// or with none, the Resources section. Each ask is new, so the same one twice scrolls twice.
struct ResourcesAsk: Equatable {
    let name: ResourceName?
    let id = UUID()
}

/// One resource: free, or held by an agent, with its line beneath.
private struct ResourceRow: View {
    @Environment(AppModel.self) private var model
    let host: MachineRef
    let state: DaemonAPI.ResourceState
    /// The daemon's time when the snapshot was taken: minutes left are counted from
    /// the same clock the lease runs by.
    let at: Date

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            dot.padding(.top, 5)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(state.displayName)
                        .appText(.reading).fontWeight(.semibold)
                        .foregroundStyle(state.isGone ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                    if let count = state.heldCount {
                        Text(count).appText(.fine).monospacedDigit().foregroundStyle(.secondary)
                    }
                    if state.endingSoon {
                        Text("ending soon")
                            .appText(.fine).fontWeight(.semibold)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .paperRaised(in: Capsule())
                    }
                }
                if let declared = state.declared {
                    Text(declared.description)
                        .appText(.fine)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                held
                if !state.line.isEmpty { line }
            }
            Spacer(minLength: 12)
            if state.holds.count == 1, let lease = state.lease {
                endButton(lease)
            }
        }
        .padding(.vertical, 2)
    }

    /// No confirmation: ending is recoverable, since the agent is told at its next
    /// lease call and can ask again; and one click matters most when an agent is
    /// holding the screen.
    private func endButton(_ lease: Lease) -> some View {
        Button("End") { Task { await model.endLease(state.name, holder: lease.holder, on: host) } }
            .buttonStyle(.paper)
            .appText(.fine)
            .accessibilityLabel("End \(name(lease.holder))'s lease on \(state.displayName)")
    }

    @ViewBuilder
    private var dot: some View {
        if state.holds.isEmpty {
            Circle().strokeBorder(.secondary, lineWidth: 1.5).frame(width: 10, height: 10)
        } else {
            Circle().fill(state.isGone ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
                .frame(width: 10, height: 10)
        }
    }

    /// One line per holder; with more than one, each has its own End.
    @ViewBuilder
    private var held: some View {
        if state.holds.isEmpty {
            Text("Free").appText(.fine).foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(state.holds, id: \.holder) { lease in
                    HStack(spacing: 0) {
                        if state.isGone { Text("Gone from this machine \u{00B7} still held by ") } else { Text("Held by ") }
                        agentLink(lease.holder)
                        Text(" since \(LeaseWords.clock(lease.grantedAt)) \u{00B7} until \(LeaseWords.clock(lease.expiresAt))"
                             + " \u{00B7} \(minutesLeft(lease)) left")
                        if state.holds.count > 1 {
                            Spacer(minLength: 8)
                            endButton(lease)
                        }
                    }
                    .appText(.fine)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// The line in order, each with when it asked and whether its wait for its turn is open
    /// (#2361): either way, its turn starts it again.
    private var line: some View {
        VStack(alignment: .leading, spacing: 4) {
            // A line that waits for the machine, not for a holder, says so (#4748).
            if let why = state.capacityWait {
                Text(CapacityWords.heldForCapacity(why))
                    .appText(.fine)
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(state.line.enumerated()), id: \.element.agentID) { index, member in
                HStack(spacing: 0) {
                    Text("\(index + 1)  ").monospacedDigit()
                    agentLink(member.agentID)
                    Text("  asked \(LeaseWords.clock(member.askedAt)) \u{00B7} "
                         + (member.isCallOpen ? "waiting for lease.granted" : "will be started"))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Button {
                        Task { await model.removeFromLine(state.name, agentID: member.agentID, on: host) }
                    } label: {
                        Image(icon: "xmark")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                    .help("Take this agent out of the line")
                    .accessibilityLabel("Take \(name(member.agentID)) out of the line for \(state.displayName)")
                }
                .appText(.fine)
            }
        }
        .padding(.top, 4)
    }

    /// An agent's name that opens its chat (US3-AS5).
    private func agentLink(_ agentID: UUID) -> some View {
        Button(name(agentID)) { model.openAgent(agentID) }
            .buttonStyle(.plain)
            .underline()
            .foregroundStyle(.primary)
            .help("Open this agent's chat")
    }

    private func name(_ agentID: UUID) -> String {
        LeaseWords.agentName(model.work.agent(agentID)?.title)
    }

    private func minutesLeft(_ lease: Lease) -> String {
        let minutes = LeaseWords.minutesLeft(until: lease.expiresAt, now: at)
        return minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(minutes) min"
    }
}
