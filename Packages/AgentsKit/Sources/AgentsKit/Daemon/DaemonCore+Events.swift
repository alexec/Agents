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

    /// `endingRun` is the key of the workflow run this event ends, when the run has
    /// already been released by the time it is raised (#102).
    @discardableResult
    func raise(_ draft: EventDraft, endingRun: String? = nil) -> Event {
        loadEventsIfNeeded()
        let appended = eventLog.append(draft, position: eventState.nextPosition, now: now())
        switch appended {
        case .new(let event):
            // The next position is written before the event is, so a daemon killed
            // between the two leaves a gap, never one position given out twice (R6).
            // A block at a time (#218): the file says the end of the block, and is
            // written again only when the block is used up.
            eventState.nextPosition = event.position + 1
            if eventState.nextPosition > eventPositionsReserved {
                eventPositionsReserved = eventState.nextPosition + Self.eventPositionBlock
                saveEventState()
            }
            appendEvent(.event(event))
            // Held to the maximum as it grows, not only at load and on the hour (#218).
            if eventLog.events.count > EventLog.maximumEvents + Self.eventCapMargin { pruneEvents() }
        case .repeated(let event):
            appendEvent(.repeatOf(event.position, at: event.latest, count: event.count))
            // A repeat is a line each time; the file is written afresh, one line for
            // each event's repeats, before they outgrow the events (#218).
            if eventStore.linesSinceRewrite > EventLog.maximumEvents + Self.eventCapMargin {
                if let error = eventStore.rewrite(eventLog) { lost(error, keeping: "the pruned list of events") }
            }
        }
        let event = appended.event
        broadcastEvents(event)
        matchWaits(event)
        fireWorkflows(for: event, endingRun: endingRun)
        return eventLog.event(at: event.position) ?? event
    }

    /// A line of the event log, written; a refusal is told (#212).
    func appendEvent(_ line: EventStore.Line) {
        if let error = eventStore.append(line) { lost(error, keeping: "an event") }
    }

    /// Write down what came of an event, and tell the windows.
    func addConsequence(_ consequence: Consequence, to position: EventPosition) {
        guard let event = eventLog.addConsequence(consequence, to: position) else { return }
        appendEvent(.consequence(consequence, position: position))
        broadcastEvents(event)
    }

    // MARK: Agents (042 contracts/catalogue.md)

    /// An event about one agent, in its project, with its id and title.
    @discardableResult
    func raiseAgentEvent(_ name: String, _ agentID: UUID, sentence: String,
                         details extra: [String: String] = [:], depth: Int? = nil,
                         endingRun: String? = nil) -> EventPosition? {
        guard let agent = agents[agentID] else { return nil }
        return raise(EventDraft(name: name, at: now(), scope: .project(folder: agent.projectFolder),
                         sentence: "\(LeaseWords.agentName(agent.title)) \(sentence)",
                         details: agentDetails(agent).merging(extra) { $1 },
                         chainDepth: depth ?? workflowChainDepth(causedBy: agentID)),
                     endingRun: endingRun).position
    }

    /// `agent.finished`, `agent.stopped` or `agent.failed`. Stopped is somebody or
    /// something choosing to stop it; failed is everything that ended it that nobody
    /// chose. The old `agent-stopped` trigger answers to both (FR-022).
    @discardableResult
    ///
    /// `parks` is whether the agent is parked once this ending is through, by its own
    /// ask or the person's park while the turn ran (073 FR-003), which `move` has
    /// decided by now. Read as "parked afterwards" rather than "parked by this ending":
    /// a finish held back for the outcome question is raised on the second ending, by
    /// when the park the first one made has already happened.
    /// The details are codes (073 FR-007, FR-008); the sentence keeps today's words.
    func raiseAgentEnding(_ agentID: UUID, next: AgentState, reason: EndedReason?, depth: Int,
                          parks: Bool = false) -> EventPosition? {
        guard let agent = agents[agentID] else { return nil }
        if next == .finished {
            let outcome = agent.report?.outcome
            var details = ["afterwards": parks ? "park" : "stay"]
            if let outcome { details["outcome"] = outcome.rawValue }
            return raiseAgentEvent("agent.finished", agentID,
                                   sentence: outcome.map { "finished: \($0.heading.lowercased())." } ?? "finished.",
                                   details: details, depth: depth)
        }
        let words = reason?.summary?.lowercased() ?? "stopped"
        if Self.isChosenStop(reason) {
            let by = switch reason {
            case .cancelled: "you"
            case .costLimit: "cost_limit"
            default: "unknown"
            }
            return raiseAgentEvent("agent.stopped", agentID, sentence: "was stopped.", details: ["by": by], depth: depth)
        }
        return raiseAgentEvent("agent.failed", agentID, sentence: "ended in an error: \(words).",
                               details: ["reason": reason?.code ?? EndedReason.unrecognised.code], depth: depth)
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
    /// Today's six trigger names keep firing from where they always have — the
    /// lifecycle funnel, the clock, the run that finished — and are not
    /// matched here, so nothing fires twice (research R7, as built). A project event
    /// reaches that project's workflows; a Mac event reaches every project's. A workflow
    /// is never fired by news of itself, which with the chain-depth limit is what stops
    /// `workflow.refused` feeding on its own refusals — nor by news of its own agents
    /// (#102), or every agent-finished workflow would run again on its own finish until
    /// the limit refused it.
    func fireWorkflows(for event: Event, endingRun: String? = nil) {
        guard workflowsAreStarted else {
            deferredEventsForWorkflows.append(event)
            return
        }
        let folders: [URL]
        switch event.scope {
        case .mac: folders = Array(workflows.keys)
        case .project(let folder): folders = [folder]
        }
        // The agent the event is about, or the one that published it (FR-023).
        let triggeringAgent = event.details["agent"].flatMap(UUID.init(uuidString:)) ?? event.publisher?.agentID
        for folder in folders {
            for workflow in (workflows[folder] ?? [:]).values.sorted(by: { $0.workflowID < $1.workflowID }) {
                guard workflow.runs(on: MachineID.current),
                      workflow.problem == nil,
                      !workflow.isArchived,
                      !(event.subject == .workflow && event.details["workflow"] == workflow.workflowID),
                      !(event.subject == .agent && triggeringAgent.map {
                          isOwnAgent($0, of: workflow, endingRun: endingRun) } == true),
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
        agents.live.values
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
        eventPositionsReserved = eventState.nextPosition
        pruneEvents()
        startPruningEvents()
    }

    func pruneEvents() {
        guard eventLog.prune(now: now()) else { return }
        if let error = eventStore.rewrite(eventLog) { lost(error, keeping: "the pruned list of events") }
    }

    /// How many positions are reserved at a time.
    static let eventPositionBlock: EventPosition = 64
    /// How far past `EventLog.maximumEvents` the log may grow before it is cut back,
    /// so a log at the maximum is not rewritten on every event.
    static let eventCapMargin = 500

    /// `events-state.json`, saying the end of the reserved block as the next position,
    /// so a restart never hands out one already given. Written only when it changed.
    func saveEventState() {
        var saved = eventState
        saved.nextPosition = max(eventState.nextPosition, eventPositionsReserved)
        // A refusal is told, not only logged (#212).
        if let error = eventStore.saveState(saved) { lost(error, keeping: "where the events have got to") }
    }

    /// Drop what the sources remember of what has gone (#218): publishes past their
    /// hour, and the branch tips of folders that are no longer projects.
    func pruneEventState() {
        loadEventsIfNeeded()
        let at = now()
        let projects = Set(projectFolders().map { Project.standardize($0).path })
        eventState.publishes = eventState.publishes.compactMapValues { dates in
            let recent = dates.filter { at.timeIntervalSince($0) < 3600 }
            return recent.isEmpty ? nil : recent
        }
        eventState.branchTips = eventState.branchTips.filter { projects.contains($0.key) }
        saveEventState()
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
