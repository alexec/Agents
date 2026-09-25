import AgentsKit
import SwiftUI

/// Who holds the Mac's shared things, and who is waiting (036 US3, US4).
///
/// A page like Spending, reached from the foot of the sidebar. What the person can do
/// here is two things: end a lease, and take an agent out of a line. There is no way
/// to take one. Only agents hold leases, and they take them themselves when they need
/// them (spec, Clarifications). A free resource therefore has no button at all.
///
/// Nothing is tinted. Holding an agreement is not a person being needed, a failure,
/// or a vouched completion, which are the only things colour means here.
struct ResourcesView: View {
    @Environment(AppModel.self) private var model

    private var snapshot: DaemonAPI.LeaseSnapshot { model.leases ?? .empty }

    /// The page's groups, always in this order. A group with nothing in it is not
    /// drawn: a Mac without Xcode has no simulators, and names only exist while leased.
    private var groups: [(title: String, rows: [DaemonAPI.ResourceState])] {
        [("Screen", .screen), ("Simulators", .simulator), ("Browsers", .browser), ("Named by agents", .named)]
            .map { title, kind in (title, snapshot.resources.filter { $0.kind == kind }) }
            .filter { !$0.rows.isEmpty }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Things on this Mac that one agent uses at a time. A lease is an agreement "
                         + "between agents, not a lock.")
                        .appText(.supporting)
                        .foregroundStyle(.secondary)
                    ForEach(groups, id: \.title) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(group.title.uppercased())
                                .appText(.fine).fontWeight(.semibold)
                                .foregroundStyle(.secondary)
                            VStack(spacing: 0) {
                                ForEach(Array(group.rows.enumerated()), id: \.element.id) { index, state in
                                    if index > 0 { Divider().padding(.leading, 32) }
                                    ResourceRow(state: state, at: snapshot.at)
                                        .id(state.name)
                                }
                            }
                            .padding(.vertical, 4)
                            .paperRaised(in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
            }
            .onAppear { scroll(proxy) }
            .onChange(of: model.resourcesFocus) { scroll(proxy) }
        }
        .navigationTitle("Resources")
        .task { await model.refreshLeases() }
    }

    /// To the resource a chat's capsule named, once.
    private func scroll(_ proxy: ScrollViewProxy) {
        guard let focus = model.resourcesFocus else { return }
        withAnimation { proxy.scrollTo(focus, anchor: .top) }
        model.resourcesFocus = nil
    }
}

/// One resource: free, or held by an agent, with its line beneath.
private struct ResourceRow: View {
    @Environment(AppModel.self) private var model
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
                    if state.endingSoon {
                        Text("ending soon")
                            .appText(.fine).fontWeight(.semibold)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .paperRaised(in: Capsule())
                    }
                }
                held
                if !state.line.isEmpty { line }
            }
            Spacer(minLength: 12)
            if state.lease != nil {
                // No confirmation: ending is recoverable, since the agent is told at its
                // next lease call and can ask again; and one click matters most when an
                // agent is holding the screen.
                Button("End") { Task { await model.endLease(state.name) } }
                    .buttonStyle(.paper)
                    .appText(.fine)
                    .accessibilityLabel("End \(holderName)'s lease on \(state.displayName)")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var dot: some View {
        if state.lease == nil {
            Circle().strokeBorder(.secondary, lineWidth: 1.5).frame(width: 10, height: 10)
        } else {
            Circle().fill(state.isGone ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
                .frame(width: 10, height: 10)
        }
    }

    @ViewBuilder
    private var held: some View {
        if let lease = state.lease {
            HStack(spacing: 0) {
                if state.isGone { Text("Gone from this Mac \u{00B7} still held by ") } else { Text("Held by ") }
                agentLink(lease.holder)
                Text(" since \(LeaseWords.clock(lease.grantedAt)) \u{00B7} until \(LeaseWords.clock(lease.expiresAt))"
                     + " \u{00B7} \(minutesLeft(lease)) left")
            }
            .appText(.fine)
            .foregroundStyle(.secondary)
        } else {
            Text("Free").appText(.fine).foregroundStyle(.secondary)
        }
    }

    /// The line in order, each with when it asked and whether its call is still open.
    private var line: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(state.line.enumerated()), id: \.element.agentID) { index, member in
                HStack(spacing: 0) {
                    Text("\(index + 1)  ").monospacedDigit()
                    agentLink(member.agentID)
                    Text("  asked \(LeaseWords.clock(member.askedAt)) \u{00B7} "
                         + (member.isCallOpen ? "waiting in its call" : "will be started"))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Button {
                        Task { await model.removeFromLine(state.name, agentID: member.agentID) }
                    } label: {
                        Image(systemName: "xmark")
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
        LeaseWords.agentName(model.agents.first { $0.id == agentID }?.title)
    }

    private var holderName: String { state.lease.map { name($0.holder) } ?? "" }

    private func minutesLeft(_ lease: Lease) -> String {
        let minutes = LeaseWords.minutesLeft(until: lease.expiresAt, now: at)
        return minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(minutes) min"
    }
}

/// The way into Resources, above Spending, with how much is held on the way past.
///
/// Always there, so the page can be found before anything is leased. The count line
/// comes and goes: absent when nothing is held or waited for.
struct ResourcesRow: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: SidebarItem?

    private var isPicked: Bool { selection == .resources }

    private var counts: String? {
        guard let resources = model.leases?.resources else { return nil }
        let held = resources.filter { $0.lease != nil }.count
        let waiting = resources.reduce(0) { $0 + $1.line.count }
        guard held + waiting > 0 else { return nil }
        return "\(held) held \u{00B7} \(waiting) waiting"
    }

    var body: some View {
        Button {
            selection = .resources
        } label: {
            HStack(alignment: .firstTextBaseline) {
                Text("Resources")
                Spacer()
                if let counts { Text(counts).monospacedDigit() }
            }
            .appText(.fine)
            .foregroundStyle(isPicked ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isPicked ? AnyShapeStyle(.selection) : AnyShapeStyle(.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Paper.sidebar)
        .help("Who holds the simulators, browsers and screen, and who is waiting")
    }
}
