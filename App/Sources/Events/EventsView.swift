import AgentsKitCore
import SwiftUI

/// What happened, what came of it, and who is still waiting (042 US2; wireframes §1).
///
/// A page like Resources, reached from the foot of the sidebar. Machine-wide on purpose:
/// the story the person wants after a night away runs across folders and the Mac, and a
/// log per folder would cut it into pieces (wireframes §6).
///
/// "Waiting now" sits at the top because it answers the other half of the same question —
/// why hasn't this agent moved? — and is absent when nobody is waiting. The list below is
/// newest first in days, filtered by folder and by kind, and it takes new events at the
/// top without moving what the person is reading.
///
/// Nothing is tinted. An event is a fact, not a state.
struct EventsView: View {
    @Environment(AppModel.self) private var model

    /// Nil: every folder and the Mac.
    @State private var scope: EventScope?
    /// Empty: every kind.
    @State private var groups: Set<EventGroup> = []
    @State private var picked: EventPosition?
    /// Whether the list is scrolled away from the top, so a new event would land
    /// out of sight.
    @State private var isScrolledDown = false
    /// The newest position the person has had in view, to count what arrived since.
    @State private var seenHead: EventPosition = 0
    /// Events, or Audit: who did what through the control plane (#996).
    @State private var pane: EventsPane = .events
    /// The envelope's provider, type and topic (#4732); nil: every one.
    @State private var provider: String?
    @State private var type: String?
    @State private var topic: String?

    private var filter: EventFilter {
        EventFilter(scope: scope, groups: groups, provider: provider, type: type, topic: topic)
    }

    /// The daemon sends pages already narrowed; narrowing here too keeps the list right
    /// in the moment between a capsule changing and its page arriving. Narrowed and cut
    /// into days once per change of the events or the filter, not per redraw (#137).
    private var shown: ShownEvents {
        model.work.shownEvents(filter)
    }

    private func unseen(_ events: [Event]) -> Int {
        isScrolledDown ? events.count(where: { $0.position > seenHead }) : 0
    }

    private var pickedEvent: Event? {
        picked.flatMap { position in
            model.work.recentEvents.first { $0.position == position }
                ?? model.work.busEvents.first { $0.position == position }
        }
    }

    /// The machine that raised it, when that is not this Mac (#4732).
    private func fromMachine(_ event: Event) -> String? {
        guard let machine = event.producerMachine else { return nil }
        if let here = model.work.eventsProducer { return event.producer == here ? nil : machine }
        // A daemon too old to say its own: the bus's rows are the ones it does not have.
        return event.position < 0 ? machine : nil
    }

    /// Where it happened: its folder or This Mac, or the machine that raised it.
    private func placeName(_ event: Event) -> String {
        fromMachine(event).map { "From \($0)" } ?? scopeName(event.scope)
    }

    var body: some View {
        Group {
            switch pane {
            case .events: events
            case .audit:
                AuditPane(control: model.controlRequests) { host in
                    host == .mac ? "this Mac" : model.hosts.label(host)
                }
            }
        }
        .navigationTitle(pane.rawValue)
        // Going to an event or to Waiting now goes back to Events.
        .onChange(of: model.eventsFocus == nil) { _, none in
            if !none { pane = .events }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Show", selection: $pane) {
                    ForEach(EventsPane.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
        }
    }

    private var events: some View {
        let shown = self.shown
        return HStack(spacing: 0) {
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
                        }
                        filters
                            .padding(.top, 20)
                        if shown.events.isEmpty {
                            Text(model.work.eventsLoaded ? emptyWords : "Loading…")
                                .appText(.supporting)
                                .foregroundStyle(.secondary)
                                .padding(.top, 20)
                        }
                        ForEach(shown.days, id: \.day) { day in
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
                        if model.work.moreEventsAnywhere {
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
                    let newCount = unseen(shown.events)
                    if newCount > 0 {
                        Button("\(newCount) new") {
                            withAnimation(ResponseMotion.response) { proxy.scrollTo(Self.top, anchor: .top) }
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
                EventDetailView(event: pickedEvent, scopeName: placeName(pickedEvent)) { picked = nil }
                    .frame(width: 300)
            }
        }
        .task(id: filter) {
            await model.refreshEvents(filter)
            seenHead = model.work.recentEvents.first?.position ?? 0
            // Other machines' events come from the bus log, which tells no one when it
            // grows: read it again while the page is open (#4732).
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                if Task.isCancelled { break }
                await model.refreshBusLog(filter)
            }
        }
    }

    private static let top = "top"

    enum EventsPane: String, CaseIterable, Identifiable {
        case events = "Events"
        case audit = "Audit"

        var id: Self { self }
    }

    private var emptyWords: String {
        scope == nil && groups.isEmpty && provider == nil && type == nil && topic == nil
            ? "Nothing has happened yet. Events appear here as agents, workflows and this Mac do things."
            : "Nothing like that has happened."
    }

    private func row(_ event: Event) -> some View {
        Button {
            picked = picked == event.position ? nil : event.position
        } label: {
            EventRow(event: event, scopeName: placeName(event),
                     openAgent: { model.openAgent($0) },
                     openWorkflow: { model.showWorkflow(folder: $0, workflowID: $1) },
                     showsEnvelope: true)
                .padding(.horizontal, 14)
                .background(picked == event.position ? AnyShapeStyle(.selection) : AnyShapeStyle(.clear))
        }
        .buttonStyle(.plain)
        .contextMenu {
            if let ref = event.ref {
                Button("Copy Ref") { EventsView.copy(ref) }
            }
        }
        .id(event.position)
    }

    // MARK: Filters

    /// The menus on one line and the kind chips on the next (#4732), so the detail beside the
    /// list leaves both room.
    private var filters: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) { menus }
            HStack(spacing: 8) { chips }
        }
    }

    @ViewBuilder private var menus: some View {
        Menu {
            Button("All") { scope = nil }
            Button("This Mac") { scope = .mac }
            Divider()
            ForEach(model.folders, id: \.folder.folder) { summary in
                Button(summary.name) { scope = .folder(folder: summary.folder.folder) }
            }
        } label: {
            Text(scope.map(scopeName) ?? "All folders").appText(.fine)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        envelopeMenu("All providers", values: \.provider, selection: $provider)
        envelopeMenu("All types", values: { $0.type ?? $0.name }, selection: $type)
        envelopeMenu("All topics", values: \.topic, selection: $topic)
    }

    @ViewBuilder private var chips: some View {
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

    /// One of the envelope's menus (#4732): every value the held events have, and the one
    /// picked, so a filter that hides them all can still be taken off.
    private func envelopeMenu(_ all: String, values: (Event) -> String?, selection: Binding<String?>) -> some View {
        let held = (model.work.recentEvents + model.work.busEvents).compactMap(values).filter { !$0.isEmpty }
        let choices = Set(held + [selection.wrappedValue].compactMap { $0 }).sorted()
        return Menu {
            Button(all) { selection.wrappedValue = nil }
            if !choices.isEmpty { Divider() }
            ForEach(choices, id: \.self) { value in
                Button(value) { selection.wrappedValue = value }
            }
        } label: {
            Text(selection.wrappedValue ?? all).appText(.fine)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: Inside

    private func scopeName(_ scope: EventScope) -> String {
        switch scope {
        case .mac: return "This Mac"
        case .folder(let folder):
            return model.folders.first { Folder.standardize($0.folder.folder) == folder }?.name
                ?? folder.lastPathComponent
        }
    }

    private func focus(_ proxy: ScrollViewProxy) {
        guard let focus = model.eventsFocus else { return }
        model.eventsFocus = nil
        switch focus {
        case .event(let position):
            scope = nil
            groups = []
            provider = nil
            type = nil
            topic = nil
            picked = position
            proxy.scrollTo(position, anchor: .center)
        }
    }
}

/// One row's piece of its day's raised card, so the rows can sit in a lazy stack and
/// still read as one card: raised paper and a rule round the outside. Rounded at the top of the first row and the foot
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
        // No shadow: a card on the page is set apart by its rule alone (Paper v2, #4974).
        shape.fill(Paper.raised)
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
                                Image(systemName: "xmark").glyph(.caption) // decorative glyph
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .help("End this wait. Nothing will start the agent again for it.")
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

/// The foot of the sidebar's way into Events (042; wireframes §1). Under the title, in
/// grey, how many sessions wait for an event; nothing when none waits. There is no count
/// of events: the log is read, it does not ask.
struct EventsRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        // The title (#587): only a session's row has something at its end. When the last
        // event came is the tooltip's; a wait's age says nothing, so the line has none.
        let waiting = EventsWords.waitingLine(model.work.waitingAgents.count)
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline) {
                Text("Events").foregroundStyle(.primary)
                Spacer()
            }
            if let waiting {
                Text(waiting).appText(.fine).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .accessibilityValue(waiting ?? "")
        .help(model.work.lastEventAt.map { "Last at \(LeaseWords.clock($0)). What happened, what came of it, and who is waiting" }
              ?? "What happened, what came of it, and who is waiting")
    }
}
