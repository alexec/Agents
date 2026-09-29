import AgentsKitCore
#if !AGENTS_STORE
import AgentsKit
#endif
import SwiftUI

/// What happened, what came of it, and who is still waiting (042 US2; wireframes §1).
///
/// A page like Resources, reached from the foot of the sidebar. Machine-wide on purpose:
/// the story the person wants after a night away runs across projects and the Mac, and a
/// log per project would cut it into pieces (wireframes §6).
///
/// "Waiting now" sits at the top because it answers the other half of the same question —
/// why hasn't this agent moved? — and is absent when nobody is waiting. The list below is
/// newest first in days, filtered by project and by kind, and it takes new events at the
/// top without moving what the person is reading.
///
/// Nothing is tinted. An event is a fact, not a state.
struct EventsView: View {
    @Environment(AppModel.self) private var model

    /// Nil: every project and the Mac.
    @State private var scope: EventScope?
    /// Empty: every kind.
    @State private var groups: Set<EventGroup> = []
    @State private var picked: EventPosition?
    /// Whether the list is scrolled away from the top, so a new event would land
    /// out of sight.
    @State private var isScrolledDown = false
    /// The newest position the person has had in view, to count what arrived since.
    @State private var seenHead: EventPosition = 0

    private var filter: EventFilter { EventFilter(scope: scope, groups: groups) }

    /// The daemon sends pages already narrowed; narrowing here too keeps the list right
    /// in the moment between a capsule changing and its page arriving.
    private var events: [Event] {
        model.work.recentEvents.filter(filter.matches)
    }

    private var unseen: Int {
        isScrolledDown ? events.filter { $0.position > seenHead }.count : 0
    }

    private var pickedEvent: Event? {
        picked.flatMap { position in model.work.recentEvents.first { $0.position == position } }
    }

    var body: some View {
        HStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    // Lazy, and the days' rows straight inside it rather than in a stack
                    // of their own, so a thousand paged-in events are not all laid out
                    // again each time one arrives. No spacing of its own: a day's rows
                    // touch, and everything else keeps the page's 20 above it.
                    LazyVStack(alignment: .leading, spacing: 0) {
                        Color.clear.frame(height: 0).id(Self.top)
                        if !model.work.waitingAgents.isEmpty {
                            WaitingNow(waiting: model.work.waitingAgents)
                                .padding(.top, 20)
                                .id(Self.waitingNow)
                        }
                        filters
                            .padding(.top, 20)
                        if events.isEmpty {
                            Text(model.work.eventsLoaded ? emptyWords : "Loading…")
                                .appText(.supporting)
                                .foregroundStyle(.secondary)
                                .padding(.top, 20)
                        }
                        ForEach(EventDay.grouped(events), id: \.day) { day in
                            Text(EventDay.heading(for: day.day).uppercased())
                                .appText(.fine).fontWeight(.semibold)
                                .foregroundStyle(.secondary)
                                .padding(.top, 20)
                                .padding(.bottom, 8)
                            ForEach(Array(day.events.enumerated()), id: \.element.position) { index, event in
                                let isFirst = index == 0, isLast = index == day.events.count - 1
                                row(event)
                                    .padding(.top, isFirst ? 4 : 0)
                                    .padding(.bottom, isLast ? 4 : 0)
                                    .overlay(alignment: .top) {
                                        if !isFirst { Divider().padding(.leading, 62) }
                                    }
                                    .background { CardSlice(isFirst: isFirst, isLast: isLast) }
                            }
                        }
                        if model.work.moreEvents {
                            Button("Show older") { Task { await model.loadOlderEvents() } }
                                .buttonStyle(.plain)
                                .appText(.fine)
                                .foregroundStyle(.secondary)
                                .padding(.top, 20)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(24)
                }
                .onScrollGeometryChange(for: Bool.self) { $0.contentOffset.y > 40 } action: { _, down in
                    isScrolledDown = down
                    if !down { seenHead = model.work.recentEvents.first?.position ?? seenHead }
                }
                .onChange(of: model.work.recentEvents.first?.position) { _, head in
                    if !isScrolledDown, let head { seenHead = head }
                }
                .overlay(alignment: .top) {
                    if unseen > 0 {
                        Button("\(unseen) new") {
                            withAnimation { proxy.scrollTo(Self.top, anchor: .top) }
                        }
                        .buttonStyle(.plain)
                        .appText(.fine)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .paperRaised(in: Capsule())
                        .padding(.top, 8)
                    }
                }
                .onAppear { focus(proxy) }
                .onChange(of: model.eventsFocus) { focus(proxy) }
            }
            if let pickedEvent {
                Divider()
                EventDetailView(event: pickedEvent, scopeName: scopeName(pickedEvent.scope)) { picked = nil }
                    .frame(width: 300)
            }
        }
        .navigationTitle("Events")
        .task(id: filter) {
            await model.refreshEvents(filter)
            seenHead = model.work.recentEvents.first?.position ?? 0
        }
    }

    private static let top = "top"
    private static let waitingNow = "waiting-now"

    private var emptyWords: String {
        scope == nil && groups.isEmpty
            ? "Nothing has happened yet. Events appear here as agents, workflows and this Mac do things."
            : "Nothing like that has happened."
    }

    private func row(_ event: Event) -> some View {
        Button {
            picked = picked == event.position ? nil : event.position
        } label: {
            EventRow(event: event, scopeName: scopeName(event.scope),
                     openAgent: { model.openAgent($0) },
                     openWorkflow: { model.showWorkflow(folder: $0, workflowID: $1) })
                .padding(.horizontal, 14)
                .background(picked == event.position ? AnyShapeStyle(.selection) : AnyShapeStyle(.clear))
        }
        .buttonStyle(.plain)
        .id(event.position)
    }

    // MARK: Filters

    private var filters: some View {
        HStack(spacing: 8) {
            Menu {
                Button("All") { scope = nil }
                Button("This Mac") { scope = .mac }
                Divider()
                ForEach(model.projects, id: \.project.folder) { summary in
                    Button(summary.name) { scope = .project(folder: summary.project.folder) }
                }
            } label: {
                Text(scope.map(scopeName) ?? "All projects").appText(.fine)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            ForEach(EventGroup.allCases, id: \.self) { group in
                let on = groups.contains(group)
                Button {
                    if on { groups.remove(group) } else { groups.insert(group) }
                } label: {
                    Text(group.title)
                        .appText(.fine)
                        .foregroundStyle(on ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(on ? AnyShapeStyle(.selection) : AnyShapeStyle(.clear), in: Capsule())
                        .paperRaised(in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Inside

    private func scopeName(_ scope: EventScope) -> String {
        switch scope {
        case .mac: return "This Mac"
        case .project(let folder):
            return model.projects.first { Project.standardize($0.project.folder) == folder }?.name
                ?? folder.lastPathComponent
        }
    }

    private func focus(_ proxy: ScrollViewProxy) {
        guard let focus = model.eventsFocus else { return }
        model.eventsFocus = nil
        switch focus {
        case .waitingNow:
            proxy.scrollTo(Self.waitingNow, anchor: .top)
        case .event(let position):
            scope = nil
            groups = []
            picked = position
            proxy.scrollTo(position, anchor: .center)
        }
    }
}

/// One row's piece of its day's raised card, so the rows can sit in a lazy stack and
/// still read as one card: raised paper, a rule round the outside, the shadow only
/// where the card's outside edge is. Rounded at the top of the first row and the foot
/// of the last.
private struct CardSlice: View {
    let isFirst: Bool
    let isLast: Bool

    private static let radius: CGFloat = 10

    var body: some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: isFirst ? Self.radius : 0,
                                           bottomLeadingRadius: isLast ? Self.radius : 0,
                                           bottomTrailingRadius: isLast ? Self.radius : 0,
                                           topTrailingRadius: isFirst ? Self.radius : 0)
        shape.fill(Paper.raised)
            .shadow(color: Paper.shadow, radius: 6, y: 2)
            // A slice's shadow falling on its neighbours would draw a band across the
            // card; keep only what falls outside it.
            .mask {
                Rectangle()
                    .padding(.horizontal, -12)
                    .padding(.top, isFirst ? -12 : 0)
                    .padding(.bottom, isLast ? -12 : 0)
            }
            .overlay { Edges(isFirst: isFirst, isLast: isLast, radius: Self.radius).stroke(Paper.rule, lineWidth: 1) }
    }

    /// The card's rule where it runs past this slice: both sides always, the top and
    /// its corners on the first, the foot and its corners on the last.
    private struct Edges: Shape {
        let isFirst: Bool
        let isLast: Bool
        let radius: CGFloat

        func path(in rect: CGRect) -> Path {
            let r = rect.insetBy(dx: 0.5, dy: 0.5)
            let top = isFirst ? r.minY : rect.minY
            let bottom = isLast ? r.maxY : rect.maxY
            var path = Path()
            path.move(to: CGPoint(x: r.minX, y: isLast ? bottom - radius : bottom))
            path.addLine(to: CGPoint(x: r.minX, y: isFirst ? top + radius : top))
            if isFirst {
                path.addArc(tangent1End: CGPoint(x: r.minX, y: top), tangent2End: CGPoint(x: r.minX + radius, y: top), radius: radius)
                path.addLine(to: CGPoint(x: r.maxX - radius, y: top))
                path.addArc(tangent1End: CGPoint(x: r.maxX, y: top), tangent2End: CGPoint(x: r.maxX, y: top + radius), radius: radius)
            } else {
                path.move(to: CGPoint(x: r.maxX, y: top))
            }
            path.addLine(to: CGPoint(x: r.maxX, y: isLast ? bottom - radius : bottom))
            if isLast {
                path.addArc(tangent1End: CGPoint(x: r.maxX, y: bottom), tangent2End: CGPoint(x: r.maxX - radius, y: bottom), radius: radius)
                path.addLine(to: CGPoint(x: r.minX + radius, y: bottom))
                path.addArc(tangent1End: CGPoint(x: r.minX, y: bottom), tangent2End: CGPoint(x: r.minX, y: bottom - radius), radius: radius)
            }
            return path
        }
    }
}

/// Every agent waiting on something, what, and until when, with ✕ to stop it (FR-013).
private struct WaitingNow: View {
    @Environment(AppModel.self) private var model
    let waiting: [DaemonAPI.WaitingAgent]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("WAITING NOW")
                .appText(.fine).fontWeight(.semibold)
                .foregroundStyle(.secondary)
            VStack(spacing: 0) {
                ForEach(Array(waiting.enumerated()), id: \.element.id) { index, agent in
                    if index > 0 { Divider().padding(.leading, 14) }
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Button {
                            model.openAgent(agent.agentID)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(agent.title).appText(.reading)
                                Text(agent.status.line)
                                    .appText(.fine)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if agent.status.cancellable {
                            Button {
                                Task { await model.cancelWait(of: agent.agentID) }
                            } label: {
                                Image(systemName: "xmark").font(.caption) // decorative glyph
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .help("Stop waiting. Nothing will start it again for this wait.")
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                }
            }
            .paperRaised(in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

/// The foot of the sidebar's way into Events (042; wireframes §1). Its line says when
/// the last thing happened. There is no count: the log is read, it does not ask.
struct EventsRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Label("Events", systemImage: "bolt")
            Spacer()
            if let last = model.work.lastEventAt {
                Text("Last \(LeaseWords.clock(last))")
                    .monospacedDigit()
                    .appText(.fine)
                    .foregroundStyle(.secondary)
            }
        }
        .help("What happened, what came of it, and who is waiting")
    }
}
