import Foundation
import AgentsKitCore

/// `project.idle` (#360): every agent in a project has stopped working.
///
/// `agent.finished` is one agent; a clean-up or a check that what a batch of agents
/// said they did really landed wants the moment the last of them stops, once. A busy
/// period starts when an agent in the project starts a turn, and ends once none is
/// starting or running and none has for `projectIdleSettle`, so a lead that ends one
/// helper and starts the next does not raise it in between. It is raised once a busy
/// period, on the way from working to quiet, never again while quiet.
///
/// An agent asking for permission is not running (`hasWorkInFlight`'s rule, 024): it
/// is counted under `waiting_on_you`, for the job to see.
///
/// A run started by `project.idle` (or `project.*`) is the clean-up itself, and its
/// agents, and the helpers they start, do not count as work: otherwise the job's own
/// finish would make the project idle again, and it would run for ever.
///
/// Memory only. A daemon restarted in the middle of a busy period starts counting
/// again from the next agent that works.
extension DaemonCore {
    /// What one project has done since it was last quiet.
    struct BusyPeriod {
        /// When the first agent in it started working.
        var since: Date
        /// Every agent that worked in it, in the order they started.
        var worked: [UUID] = []
        /// The wait before saying it is quiet, while nothing runs.
        var settling: Task<Void, Never>?
        /// Bumped each time something works again, so a settle that woke late is ignored.
        var generation = 0
    }

    /// A test's own settle time, rather than a minute.
    func useProjectIdleSettle(_ settle: Duration) {
        projectIdleSettle = settle
    }

    /// Called on every agent state change, from the one funnel they all pass through.
    func watchForIdle(in folder: URL) {
        let members = agents.agents(in: folder)
        let working = members.filter { ($0.state == .starting || $0.state == .running) && !isIdleJob($0) }
        if !working.isEmpty {
            var period = busyPeriods[folder] ?? BusyPeriod(since: now())
            for agent in working where !period.worked.contains(agent.id) { period.worked.append(agent.id) }
            period.settling?.cancel()
            period.settling = nil
            period.generation += 1
            busyPeriods[folder] = period
            return
        }
        guard var period = busyPeriods[folder], period.settling == nil, !period.worked.isEmpty else { return }
        let generation = period.generation
        let settle = projectIdleSettle
        period.settling = Task { [weak self] in
            try? await Task.sleep(for: settle)
            guard !Task.isCancelled else { return }
            await self?.settled(folder, generation: generation)
        }
        busyPeriods[folder] = period
    }

    /// The settle ran out: say so, if nothing has worked since.
    private func settled(_ folder: URL, generation: Int) {
        guard let period = busyPeriods[folder], period.generation == generation else { return }
        let stillWorking = agents.agents(in: folder).contains {
            ($0.state == .starting || $0.state == .running) && !isIdleJob($0)
        }
        guard !stillWorking else { return }
        busyPeriods[folder] = nil
        raiseProjectIdle(folder, period)
    }

    private func raiseProjectIdle(_ folder: URL, _ period: BusyPeriod) {
        var counts: [String: Int] = ["finished": 0, "blocked": 0, "waiting_on_you": 0, "stopped": 0, "failed": 0]
        for id in period.worked {
            guard let agent = agents[id] else { continue }
            counts[standing(of: agent), default: 0] += 1
        }
        var details = counts.mapValues(String.init)
        details["agents"] = String(period.worked.count)
        details["since"] = ISO8601DateFormatter().string(from: period.since)
        details["ids"] = period.worked.map(\.uuidString).joined(separator: ",")
        let n = period.worked.count
        let tally = ["finished", "blocked", "waiting_on_you", "stopped", "failed"]
            .compactMap { key in counts[key].flatMap { $0 > 0 ? "\($0) \(key.replacingOccurrences(of: "_", with: " "))" : nil } }
            .joined(separator: ", ")
        raise(EventDraft(name: "project.idle", at: now(), scope: .project(folder: folder),
                         sentence: "Every agent here has stopped: \(n) worked (\(tally)).",
                         details: details))
    }

    /// How an agent that worked stands now, as the event counts it.
    private func standing(of agent: Agent) -> String {
        switch agent.state {
        case .waitingOnUser: return "waiting_on_you"
        case .stopped: return Self.isChosenStop(agent.endedReason) ? "stopped" : "failed"
        case .finished, .archived, .starting, .running, .queued:
            if WaitStatus.of(agent, names: { _ in nil }) != nil { return "blocked" }
            if agent.report?.outcome == .needsAnswer { return "waiting_on_you" }
            if agent.report?.outcome == .blocked { return "blocked" }
            return "finished"
        }
    }

    /// Whether this agent is doing a `project.idle` workflow's work, or is a helper of
    /// one that is: the clean-up, whose own work must not make the project busy.
    func isIdleJob(_ agent: Agent) -> Bool {
        if let run = runInFlight(for: agent.id)?.run, Self.answersIdle(run.trigger) { return true }
        if let workflowID = agent.startedByWorkflow,
           let workflow = workflows[agent.projectFolder]?.values.first(where: { $0.workflowID == workflowID }),
           workflow.mode != .triggering, workflow.triggers.contains(where: Self.answersIdle) { return true }
        // One step only, as `workflowChainDepth` goes.
        if let starter = agent.startedByAgent, starter != agent.id, let parent = agents[starter],
           parent.startedByAgent == nil {
            return isIdleJob(parent)
        }
        return false
    }

    private static func answersIdle(_ trigger: WorkflowTrigger) -> Bool {
        trigger.patterns.contains { $0.name == "project.idle" || $0.name == "project.*" }
    }
}
