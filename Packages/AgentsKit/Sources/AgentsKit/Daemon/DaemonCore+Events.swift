import Foundation
import AgentsKitCore

/// Something happened: the one funnel (042 R1).
///
/// Every source calls `raise`, and nothing else decides who hears about an event. It
/// gives the event its place, writes it down, tells the windows, then matches it
/// against every open wait and every workflow trigger, in that order and with no
/// `await` in between — so a wait made in the same instant is either before the event
/// and matched, or after it and waiting from after it. Nothing slips between.
extension DaemonCore {
    // MARK: Raising

    @discardableResult
    func raise(_ draft: EventDraft) -> Event {
        loadEventsIfNeeded()
        let appended = eventLog.append(draft, position: eventState.nextPosition, now: now())
        switch appended {
        case .new(let event):
            // The next position is written before the event is, so a daemon killed
            // between the two leaves a gap, never one position given out twice (R6).
            eventState.nextPosition = event.position + 1
            eventStore.saveState(eventState)
            eventStore.append(.event(event))
        case .repeated(let event):
            eventStore.append(.repeatOf(event.position, at: event.latest, count: event.count))
        }
        let event = appended.event
        broadcastEvents(event)
        matchWaits(event)
        fireWorkflows(for: event)
        return eventLog.event(at: event.position) ?? event
    }

    /// Write down what came of an event, and tell the windows.
    func addConsequence(_ consequence: Consequence, to position: EventPosition) {
        guard let event = eventLog.addConsequence(consequence, to: position) else { return }
        eventStore.append(.consequence(consequence, position: position))
        broadcastEvents(event)
    }

    // MARK: Workflows

    /// Fire every workflow whose trigger this event matches. Filled in with US3.
    func fireWorkflows(for event: Event) {}

    // MARK: Reading

    public func eventsPage(_ request: DaemonAPI.EventsListRequest) -> DaemonAPI.EventsPage {
        loadEventsIfNeeded()
        let page = eventLog.query(before: request.before, limit: request.limit,
                                  scopes: request.scope.map { [$0] },
                                  groups: request.groups.map(Set.init))
        return DaemonAPI.EventsPage(events: page.events, waiting: waitingAgents(), hasMore: page.hasMore)
    }

    /// Every agent that is waiting on something, for the page's Waiting now strip.
    /// Both kinds of waiting, as `WaitStatus` says them.
    func waitingAgents() -> [DaemonAPI.WaitingAgent] {
        agents.values
            .filter { $0.state != .archived }
            .compactMap { agent -> (Agent, WaitStatus)? in
                WaitStatus.of(agent, names: { self.agents[$0]?.title }).map { (agent, $0) }
            }
            .sorted { ($0.0.eventWait?.since ?? $0.0.lastActivityAt) < ($1.0.eventWait?.since ?? $1.0.lastActivityAt) }
            .map { DaemonAPI.WaitingAgent(agentID: $0.0.id, title: $0.0.title ?? "Untitled",
                                         folder: $0.0.projectFolder, status: $0.1) }
    }

    /// Tell the windows: the event that is new or changed, if one is, and who waits.
    func broadcastEvents(_ event: Event? = nil) {
        broadcast(DaemonAPI.Notification.eventsChanged,
                  DaemonAPI.EventsChange(event: event, waiting: waitingAgents()))
    }

    // MARK: By hand

    /// `events/raise`: a debug build on a scratch root raising an event by hand, with
    /// consequences if it wants them, so the page can be seen before anything real
    /// raises one. Never on the real root, where an invented event would be a lie in
    /// the one place the person goes to find out what happened.
    public func raiseByHand(_ request: DaemonAPI.EventRaiseRequest) throws -> Event {
        #if DEBUG
        guard !locations.isStandard else {
            throw JSONRPCError(code: DaemonAPI.Failure.eventRefused,
                               message: "Events are raised by hand only on a scratch root.")
        }
        if let problem = request.draft.problem {
            throw JSONRPCError(code: DaemonAPI.Failure.eventRefused, message: problem)
        }
        let event = raise(request.draft)
        for consequence in request.consequences ?? [] { addConsequence(consequence, to: event.position) }
        return eventLog.event(at: event.position) ?? event
        #else
        throw JSONRPCError(code: DaemonAPI.Failure.eventRefused, message: "Events are raised by hand only in a debug build.")
        #endif
    }

    // MARK: Keeping

    /// The log and the sources' memory from disk, the first time either is wanted,
    /// with anything past keeping dropped.
    func loadEventsIfNeeded() {
        guard !eventLogIsLoaded else { return }
        eventLogIsLoaded = true
        eventLog = eventStore.load()
        eventState = eventStore.loadState()
        // A state file lost or older than the log must never hand out a position the
        // log already has.
        if eventState.nextPosition <= eventLog.head { eventState.nextPosition = eventLog.head + 1 }
        pruneEvents()
        startPruningEvents()
    }

    func pruneEvents() {
        if eventLog.prune(now: now()) { eventStore.rewrite(eventLog) }
    }

    private func startPruningEvents() {
        guard eventPruner == nil else { return }
        eventPruner = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60 * 60))
                guard let self, !Task.isCancelled else { return }
                await self.pruneEvents()
            }
        }
    }
}
