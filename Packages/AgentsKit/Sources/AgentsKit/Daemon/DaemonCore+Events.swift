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

    // MARK: Agents (042 contracts/catalogue.md)

    /// An event about one agent, in its project, with its id and title.
    @discardableResult
    func raiseAgentEvent(_ name: String, _ agentID: UUID, sentence: String,
                         details extra: [String: String] = [:], depth: Int? = nil) -> EventPosition? {
        guard let agent = agents[agentID] else { return nil }
        return raise(EventDraft(name: name, at: now(), scope: .project(folder: agent.projectFolder),
                         sentence: "\(LeaseWords.agentName(agent.title)) \(sentence)",
                         details: agentDetails(agent).merging(extra) { $1 },
                         chainDepth: depth ?? workflowChainDepth(causedBy: agentID))).position
    }

    /// `agent.finished`, `agent.stopped` or `agent.failed`. Stopped is somebody or
    /// something choosing to stop it; failed is everything that ended it that nobody
    /// chose. The old `agent-stopped` trigger answers to both (FR-022).
    @discardableResult
    func raiseAgentEnding(_ agentID: UUID, next: AgentState, reason: EndedReason?, depth: Int) -> EventPosition? {
        guard let agent = agents[agentID] else { return nil }
        if next == .finished {
            let outcome = agent.report?.outcome
            return raiseAgentEvent("agent.finished", agentID,
                                   sentence: outcome.map { "finished: \($0.heading.lowercased())." } ?? "finished.",
                                   details: outcome.map { ["outcome": $0.rawValue] } ?? [:], depth: depth)
        }
        let words = reason?.summary?.lowercased() ?? "stopped"
        if Self.isChosenStop(reason) {
            return raiseAgentEvent("agent.stopped", agentID, sentence: "was stopped.", details: ["by": words], depth: depth)
        }
        return raiseAgentEvent("agent.failed", agentID, sentence: "ended in an error: \(words).",
                               details: ["reason": words], depth: depth)
    }

    static func isChosenStop(_ reason: EndedReason?) -> Bool {
        switch reason {
        case .cancelled, .costLimit, nil: return true
        default: return false
        }
    }

    // MARK: Workflows

    /// Fire every workflow with a new-style trigger this event matches (042 FR-021).
    ///
    /// Today's nine trigger names keep firing from where they always have — the
    /// lifecycle funnel, 038's pull-request sweep, the run that finished — and are not
    /// matched here, so nothing fires twice (research R7, as built). A project event
    /// reaches that project's workflows; a Mac event reaches every project's. A workflow
    /// is never fired by news of itself, which with the chain-depth limit is what stops
    /// `workflow.refused` feeding on its own refusals.
    func fireWorkflows(for event: Event) {
        guard workflowsAreStarted else {
            deferredEventsForWorkflows.append(event)
            return
        }
        let folders: [URL]
        switch event.scope {
        case .mac: folders = Array(workflows.keys)
        case .project(let folder): folders = [folder]
        }
        let records = workflowStore.load()
        // The agent the event is about, or the one that published it (FR-023).
        let triggeringAgent = event.details["agent"].flatMap(UUID.init(uuidString:)) ?? event.publisher?.agentID
        for folder in folders {
            for workflow in (workflows[folder] ?? [:]).values.sorted(by: { $0.workflowID < $1.workflowID }) {
                guard workflow.problem == nil,
                      records.state(folder: folder, workflowID: workflow.workflowID)?.isArchived != true,
                      !(event.subject == .workflow && event.details["workflow"] == workflow.workflowID),
                      let trigger = workflow.triggers.first(where: { $0.matches(event) }) else { continue }
                // Detached, as `workflowsRespond` does: `raise` is called from inside
                // the actor, and firing awaits things that call back into it.
                Task { [weak self] in
                    await self?.fire(workflow, on: trigger, triggeringAgentID: triggeringAgent,
                                     depth: event.chainDepth, causingEvent: event.position)
                }
            }
        }
    }

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
