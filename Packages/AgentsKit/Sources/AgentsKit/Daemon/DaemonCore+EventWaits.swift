import Foundation
import AgentsKitCore

/// Agents waiting for something to happen, and saying that something has (042 US1, US4).
///
/// A wait is 036's lease line with events in place of a resource. The call is held open
/// for up to `eventHoldLimit`; an event inside that answers it, and after it the call
/// says "still waiting" and the agent may end its turn. An event after that clears the
/// wait and queues an app prompt in one write — 039's `queueResume` shape — so an agent
/// is started again once for one wait, across a restart as much as within one.
///
/// Every check and write here happens before the first `await` of the call that makes
/// it, which on this actor is the whole of the lock. The one exception is asking the
/// servers what they offer (#577), which comes first, before anything is checked or
/// written that it could race.
extension DaemonCore {
    // MARK: wait_for_event

    public func waitForEvent(_ request: DaemonAPI.EventWaitRequest) async throws -> String {
        let caller = try eventCaller(request.token)
        loadEventsIfNeeded()
        let scopes = eventScopes(for: caller)
        switch (request.action ?? "wait").lowercased() {
        case "list":
            return EventCatalogue.describe()
        case "recent":
            let limit = min(max(request.limit ?? 20, 1), 50)
            let page = eventLog.query(limit: limit, scopes: scopes)
            guard !page.events.isEmpty else { return EventWords.noRecent + "\n" + EventWords.recentFooter(head: eventLog.head) }
            return (page.events.map(EventWords.recentLine) + [EventWords.recentFooter(head: eventLog.head)])
                .joined(separator: "\n")
        case "wait":
            break
        default:
            throw eventRefusal("action is wait, recent or list.")
        }

        // The wait, checked whole before anything is written.
        let names = (request.events ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !names.isEmpty else { throw eventRefusal(EventWords.nothingNamed) }
        // Every wait ends by itself (#572), whatever it waits on.
        guard let minutes = request.untilMinutes else { throw eventRefusal(EventWords.deadlineRequired()) }
        guard EventWait.deadlineMinutes.contains(minutes) else { throw eventRefusal(EventWords.badDeadline()) }
        let filters = request.where ?? [:]
        var patterns: [EventPattern] = []
        for name in names {
            switch EventPattern.parse(name, filters: filters) {
            // A server's event is matched by its subscription, not its details: `where`
            // goes to the server (#577).
            case .success(let pattern) where EventWait.isServerPattern(pattern.name):
                patterns.append(EventPattern(pattern.name))
            case .success(let pattern): patterns.append(pattern)
            case .failure(let problem): throw eventRefusal(problem.message)
            }
        }
        // A server never raises what only a Mac does (#372): a wait on nothing else
        // could only ever time out, so it is refused; one with something else is
        // kept, and told.
        let neverHere = raisesMacOnlyEvents ? [] : patterns.map(\.name).filter(EventCatalogue.isMacOnly)
        if !neverHere.isEmpty, neverHere.count == patterns.count {
            throw eventRefusal(EventWords.neverHere(neverHere) + " Nothing is waiting.")
        }
        // A server's event is a subscription the wait holds, as a trigger's is (#577):
        // checked against what the project's servers offer, `where` as its arguments.
        // Asked before anything below, which must not be split by an `await`.
        let from = request.from ?? eventLog.head
        let serverNames = patterns.map(\.name).filter(EventWait.isServerPattern)
        let servers: MCPWaitCheck
        switch await checkMCPWait(serverNames, where: request.where ?? [:], project: caller.projectFolder) {
        case .success(let check): servers = check
        case .failure(let refusal): throw refusal
        }
        guard agents[caller.id] != nil else { throw noAgent() }
        let warning = (neverHere.isEmpty ? "" : EventWords.neverHere(neverHere) + " ") + servers.warning
        let at = now()
        let wait = EventWait(patterns: patterns, from: from,
                             deadline: at.addingTimeInterval(TimeInterval(minutes) * 60),
                             since: at, serverEvents: serverNames.isEmpty ? nil : servers.events)

        // Something already after `from`: answered now, and nothing is left waiting.
        if let hit = eventLog.events.first(where: { scopes.contains($0.scope) && wait.matches($0) }) {
            let previous = endWait(caller.id, by: .agent, quietly: true)
            return warning + (previous.map(EventWords.replaced) ?? "") + EventWords.matched(hit)
        }

        let previous = endWait(caller.id, by: .agent, quietly: true)
        guard var agent = agents[caller.id] else { throw noAgent() }
        agent.eventWait = wait
        changed(agent)
        startMCPWait(servers)
        broadcastEvents()
        armEventWaitTimer()
        let prefix = warning + EventWords.subscribed(servers.events) + (previous.map(EventWords.replaced) ?? "")
        // Parked before anything is awaited, so an event in the next instant finds the
        // call to answer rather than starting the agent again.
        let answer = await withCheckedContinuation { continuation in
            openEventWaits[caller.id] = continuation
            openEventWaitStarted[caller.id] = at
            scheduleEventHold(caller.id, waitID: wait.id)
        }
        switch answer {
        case .success(let text): return prefix + text
        case .failure(let error): throw error
        }
    }

    // MARK: cancel_wait, and the person's ✕

    public func cancelWait(_ request: DaemonAPI.EventTokenRequest) throws -> String {
        let caller = try eventCaller(request.token)
        guard let wait = endWait(caller.id, by: .agent) else {
            throw JSONRPCError(code: DaemonAPI.Failure.noWait, message: EventWords.notWaiting)
        }
        return EventWords.stoppedWaiting(wait)
    }

    /// `events/cancelWait`: the person, from the Mac (FR-013). Nothing will start the
    /// agent again for it.
    public func cancelWaitByPerson(_ request: DaemonAPI.CancelWaitRequest) throws -> [DaemonAPI.WaitingAgent] {
        guard agents[request.agentID] != nil else { throw noAgent() }
        guard endWait(request.agentID, by: .person) != nil else {
            throw JSONRPCError(code: DaemonAPI.Failure.noWait, message: "That agent is not waiting on anything.")
        }
        return waitingAgents()
    }

    /// End an agent's open wait without resuming it: cancelled, replaced, stopped,
    /// archived, or taken over by the person's prompt. A call still open hears why.
    /// Returns the wait that ended, or nil if there was none.
    @discardableResult
    func endWait(_ agentID: UUID, by canceller: EventWaitEnding.Canceller, quietly: Bool = false) -> EventWait? {
        guard var agent = agents[agentID], let wait = agent.eventWait, wait.isOpen else { return nil }
        agent.eventWait = nil
        changed(agent)
        mcpWaitEnded(wait)
        if let call = openEventWaits.removeValue(forKey: agentID) {
            openEventWaitStarted.removeValue(forKey: agentID)
            call.resume(returning: .success(quietly ? EventWords.replaced(wait) : EventWords.ended(wait, by: canceller)))
        }
        broadcastEvents()
        armEventWaitTimer()
        return wait
    }

    // MARK: Matching (called from `raise`)

    /// Every wait this event satisfies. No `await`: `raise` calls this between giving
    /// the event its place and returning, and nothing may slip in between.
    func matchWaits(_ event: Event) {
        // Only agents with a wait: the rest can't match (#164).
        for id in Array(agents.withEventWait) {
            // Never on news of itself: an agent that waits on `agent.*` and then ends
            // its turn would otherwise be woken by its own ending.
            guard var agent = agents[id], var wait = agent.eventWait,
                  isInScope(event, for: agent), wait.matches(event),
                  event.details["agent"] != id.uuidString else { continue }
            if wait.isOpen {
                mcpWaitEnded(wait)
                if let call = openEventWaits.removeValue(forKey: id) {
                    // Its call is still open: answered, and nothing is left waiting.
                    let started = openEventWaitStarted.removeValue(forKey: id) ?? wait.since
                    agent.eventWait = nil
                    changed(agent)
                    call.resume(returning: .success(EventWords.matched(event,
                        waited: Int(now().timeIntervalSince(started).rounded()))))
                } else {
                    // Its turn has ended. The one write: the wait ends and the prompt
                    // that says so is queued, together.
                    let prompt = QueuedPrompt(text: EventWords.wake(event, extraMatches: 0), from: .app)
                    wait.ending = .matched(position: event.position, extraMatches: 0)
                    wait.resumePromptID = prompt.id
                    agent.eventWait = wait
                    agent.queuedPrompts.append(prompt)
                    changed(agent)
                    Task { await self.sendEventResume(id, promptID: prompt.id, position: event.position) }
                }
                addConsequence(.woke(agentID: id, title: agent.title ?? "Untitled"), to: event.position)
                broadcastEvents()
                armEventWaitTimer()
            } else if case .matched(let position, let extra) = wait.ending, let promptID = wait.resumePromptID,
                      let index = agent.queuedPrompts.firstIndex(where: { $0.id == promptID }),
                      event.position != position, let first = eventLog.event(at: position) {
                // Woken, and not yet running: this one is counted in the prompt it
                // will read, rather than waking it twice (spec, Edge Cases).
                wait.ending = .matched(position: position, extraMatches: extra + 1)
                agent.eventWait = wait
                agent.queuedPrompts[index].text = EventWords.wake(first, extraMatches: extra + 1)
                changed(agent)
            }
        }
    }

    /// Send a queued wake, and if it cannot go, say so (spec, Edge Cases): the wait is
    /// dropped, the event records that the agent could not be woken, and the agent's
    /// chat names what it missed.
    func sendEventResume(_ agentID: UUID, promptID: UUID, position: EventPosition?) async {
        var failure: String?
        do {
            try await sendNextQueued(to: agentID)
        } catch {
            failure = reason(error)
        }
        guard var agent = agents[agentID], agent.queuedPrompts.first?.id == promptID,
              !agent.state.hasTurnInFlight, turnTasks[agentID] == nil, !sending.contains(agentID)
        else { return }
        // Still first, nothing in flight, and nothing threw: a spending limit holds it.
        let why = failure ?? "a spending limit is holding it"
        agent.queuedPrompts.removeAll { $0.id == promptID }
        if var wait = agent.eventWait {
            wait.ending = .couldNotWake(reason: why)
            agent.eventWait = wait
        }
        changed(agent)
        let event = position.flatMap { eventLog.event(at: $0) }
        await record(.runtimeNote(EventWords.couldNotWake(event, reason: why)), for: agentID)
        if let position {
            addConsequence(.couldNotWake(agentID: agentID, title: agent.title ?? "Untitled", reason: why),
                           to: position)
        }
        broadcastEvents()
    }

    // MARK: Holding the call, and deadlines

    private func scheduleEventHold(_ agentID: UUID, waitID: UUID) {
        let limit = eventHoldLimit
        Task { [weak self] in
            try? await Task.sleep(for: limit)
            await self?.eventHoldReached(agentID, waitID: waitID)
        }
    }

    /// The call has been held as long as a call may. It answers "still waiting", and the
    /// wait stays: the agent will be started when its event comes (FR-008).
    private func eventHoldReached(_ agentID: UUID, waitID: UUID) {
        guard let wait = agents[agentID]?.eventWait, wait.id == waitID, wait.isOpen,
              let call = openEventWaits.removeValue(forKey: agentID) else { return }
        openEventWaitStarted.removeValue(forKey: agentID)
        call.resume(returning: .success(EventWords.stillWaiting(wait)))
        // Now it is blocked: its call has come back without its event, and its turn
        // will end waiting. Raised here, not at the call, because a call answered
        // inside the hold never left the agent waiting at all.
        if let agent = agents[agentID] {
            raise(EventDraft(name: "agent.blocked", at: now(), scope: .project(folder: agent.projectFolder),
                             sentence: "\(LeaseWords.agentName(agent.title)) is waiting for \(wait.label).",
                             details: agentDetails(agent).merging(["waiting_on": wait.label]) { $1 },
                             chainDepth: workflowChainDepth(causedBy: agent.id)))
        }
    }

    /// One timer, aimed at the earliest deadline of any open wait.
    func armEventWaitTimer() {
        eventWaitTimer?.cancel()
        let deadlines = agents.withEventWait.compactMap { agents[$0] }.compactMap { agent -> Date? in
            guard let wait = agent.eventWait, wait.isOpen else { return nil }
            return wait.deadline
        }
        guard let next = deadlines.min() else {
            eventWaitTimer = nil
            return
        }
        let delay = max(0, next.timeIntervalSince(now()))
        eventWaitTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.eventWaitDeadlinesPassed()
        }
    }

    /// Every open wait whose deadline has come ends timed out (US1-AS5): an open call
    /// hears it, and an agent whose turn has ended is started again to be told.
    func eventWaitDeadlinesPassed() {
        let at = now()
        // Only the agents with a wait, not every agent there is (#218).
        for id in Array(agents.withEventWait) {
            guard var agent = agents[id], var wait = agent.eventWait, wait.isDue(now: at) else { continue }
            mcpWaitEnded(wait)
            if let call = openEventWaits.removeValue(forKey: id) {
                openEventWaitStarted.removeValue(forKey: id)
                agent.eventWait = nil
                changed(agent)
                call.resume(returning: .success(EventWords.timedOut(wait, at: at)))
            } else {
                let prompt = QueuedPrompt(text: EventWords.timedOut(wait, at: at), from: .app)
                wait.ending = .timedOut
                wait.resumePromptID = prompt.id
                agent.eventWait = wait
                agent.queuedPrompts.append(prompt)
                changed(agent)
                Task { await self.sendEventResume(id, promptID: prompt.id, position: nil) }
            }
        }
        broadcastEvents()
        armEventWaitTimer()
    }

    // MARK: Restarts (FR-014)

    /// What a restart owes the waiting. No call survives one, so every open wait is an
    /// agent to start when its event comes; a wake the last daemon queued and never
    /// sent is sent, once; and deadlines are aimed again, so one that passed while
    /// nothing was running ends now. Nothing is raised for the time the daemon was down.
    func resumeEventWaitsAfterRestart() async {
        loadEventsIfNeeded()
        // A wait an earlier build saved with no deadline gets one now (#572), so none
        // can hang for ever.
        let latest = now().addingTimeInterval(TimeInterval(EventWait.deadlineMinutes.upperBound) * 60)
        for id in Array(agents.withEventWait) {
            guard var agent = agents[id], var wait = agent.eventWait, wait.isOpen, wait.deadline == nil else { continue }
            wait.deadline = latest
            agent.eventWait = wait
            changed(agent)
        }
        for agent in agents.withEventWait.compactMap({ agents[$0] }) {
            guard let wait = agent.eventWait, !wait.isOpen, let promptID = wait.resumePromptID,
                  agent.queuedPrompts.first?.id == promptID else { continue }
            var position: EventPosition?
            if case .matched(let at, _) = wait.ending { position = at }
            await sendEventResume(agent.id, promptID: promptID, position: position)
        }
        armEventWaitTimer()
        eventWaitDeadlinesPassed()
    }

    // MARK: publish_event (US4)

    public static let publishesPerHour = 30

    public func publishEvent(_ request: DaemonAPI.EventPublishRequest) throws -> String {
        let caller = try eventCaller(request.token)
        loadEventsIfNeeded()
        let name = request.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard name.hasPrefix("custom.") else { throw eventRefusal(EventWords.publishOutsideCustom(name)) }
        guard EventCatalogue.isCustom(name) else {
            throw eventRefusal(EventPatternProblem.badCustomName(name).message)
        }
        let at = now()
        let key = caller.id.uuidString
        let recent = (eventState.publishes[key] ?? []).filter { at.timeIntervalSince($0) < 3600 }
        if recent.count >= Self.publishesPerHour, let oldest = recent.min() {
            throw eventRefusal(EventWords.publishLimit(Self.publishesPerHour, until: oldest.addingTimeInterval(3600)))
        }
        let message = request.message?.trimmingCharacters(in: .whitespacesAndNewlines)
        let draft = EventDraft(name: name, at: at, scope: .project(folder: caller.projectFolder),
                               sentence: "\(LeaseWords.agentName(caller.title)) published \(name).",
                               details: request.details ?? [:],
                               publisher: EventPublisher(agentID: caller.id, title: caller.title ?? "Untitled"),
                               message: message?.isEmpty == true ? nil : message,
                               chainDepth: workflowChainDepth(causedBy: caller.id))
        if let problem = draft.problem { throw eventRefusal(problem) }
        // Every agent's past their hour go with this one's, so the map holds only the
        // publishers of the last hour (#218).
        eventState.publishes = eventState.publishes.compactMapValues { dates in
            let kept = dates.filter { at.timeIntervalSince($0) < 3600 }
            return kept.isEmpty ? nil : kept
        }
        eventState.publishes[key] = recent + [at]
        saveEventState()
        return EventWords.published(raise(draft))
    }

    // MARK: Inside

    private func eventCaller(_ token: String) throws -> Agent {
        guard let id = appTokens[token], let agent = agents[id] else {
            throw JSONRPCError(code: DaemonAPI.Failure.noSuchAgent, message: LeaseWords.noConversation)
        }
        return agent
    }

    /// The Mac's events and the agent's own project's, and nothing else (FR-015).
    func eventScopes(for agent: Agent) -> Set<EventScope> {
        [.mac, .project(folder: agent.projectFolder)]
    }

    func isInScope(_ event: Event, for agent: Agent) -> Bool {
        event.scope == .mac || event.scope == .project(folder: agent.projectFolder)
    }

    /// `agent` and `agent_title`, for an event about this agent, and what it was at
    /// that moment (073 FR-001): its labels (keys, sorted, comma-joined; labels cannot
    /// hold a comma), its runtime, and who started it. A helper a workflow's agent
    /// started is the agent's, not the workflow's.
    func agentDetails(_ agent: Agent) -> [String: String] {
        let startedBy = agent.startedByAgent != nil ? "agent" : agent.startedByWorkflow != nil ? "workflow" : "person"
        return ["agent": agent.id.uuidString, "agent_title": agent.title ?? "Untitled",
                "labels": Set(agent.labels.map(\.normalizedValue)).sorted().joined(separator: ","),
                "runtime": agent.runtimeID, "started_by": startedBy]
    }

    private func eventRefusal(_ message: String) -> JSONRPCError {
        JSONRPCError(code: DaemonAPI.Failure.eventRefused, message: message)
    }

    private func noAgent() -> JSONRPCError {
        JSONRPCError(code: DaemonAPI.Failure.noSuchAgent, message: "That agent is not here.")
    }

    /// For tests: a shorter hold.
    func useForEvents(holdLimit: Duration) {
        eventHoldLimit = holdLimit
    }

    /// A test's way of being a Linux server, which raises no Mac-only event (#372).
    func actAsServer() {
        raisesMacOnlyEvents = false
    }
}
