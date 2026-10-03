import AgentsKitCore
import Foundation

/// Update now (#146): the Dashboard's button. It runs the project's workflow labelled
/// `dashboard` as Run now would, or, with none, starts a one-off agent with a prompt of
/// the app's own (Alex's choice). Either way one at a time, and not again within five
/// minutes of the last start.
extension DaemonCore {
    /// The project's dashboard workflow: not archived, labelled `dashboard`, the first by
    /// file name when several are.
    func dashboardWorkflow(in project: URL) -> Workflow? {
        if workflows[project] == nil { adoptWorkflows(in: project) }
        return (workflows[project] ?? [:]).values
            .filter { !$0.isArchived && $0.settings.labels.contains(DashboardUpdate.label) }
            .min { $0.workflowID < $1.workflowID }
    }

    /// Where Update now stands for a project, as the page draws it.
    func dashboardUpdate(_ project: URL) -> DashboardUpdate {
        if let workflow = dashboardWorkflow(in: project) {
            let summary = summary(for: workflow)
            var agentID = workflowRuns[workflow.id]?.agentID
            if agentID == nil, case .ran(let ran, _)? = summary.lastOutcome { agentID = ran }
            let blocked: String? = if summary.awaitingApproval != nil {
                "\(workflow.name) is waiting for approval"
            } else if let limit = summary.overLimit {
                limit.message
            } else if case .unreadable(let detail)? = workflow.problem {
                detail
            } else {
                nil
            }
            return DashboardUpdate(workflowID: workflow.workflowID, name: workflow.name,
                                   isRunning: summary.isRunning, agentID: agentID,
                                   lastStartedAt: summary.lastFiredAt,
                                   lastFailed: !summary.isRunning && Self.updateFailed(agentID.flatMap { agents[$0] }),
                                   blocked: blocked)
        }
        guard let updater = dashboardStore.state(project).updater else { return DashboardUpdate() }
        let agent = updater.agentID.flatMap { agents[$0] }
        let running: Bool = if let agent {
            [.starting, .running, .waitingOnUser].contains(agent.state)
        } else {
            // Still starting: a daemon that went mid-start leaves no agent, so this lapses.
            updater.agentID == nil && now().timeIntervalSince(updater.startedAt) < 120
        }
        return DashboardUpdate(isRunning: running, agentID: updater.agentID, lastStartedAt: updater.startedAt,
                               lastFailed: !running && Self.updateFailed(agent))
    }

    /// Stuck, or stopped before it said how it went.
    static func updateFailed(_ agent: Agent?) -> Bool {
        guard let agent else { return false }
        if agent.report?.outcome == .stuck { return true }
        return agent.state == .stopped && agent.report == nil
    }

    /// The press. Refused, saying why, when it would start nothing.
    public func updateDashboard(_ request: DaemonAPI.DashboardRequest) async throws -> DashboardUpdate {
        let project = Project.standardize(request.folder)
        try requireFolder(project)
        let state = dashboardUpdate(project)
        if state.isRunning {
            throw dashboardRefusal("\(state.name) is already running.")
        }
        if let blocked = state.blocked {
            throw dashboardRefusal("Update now can't start: \(blocked).")
        }
        if let ready = state.readyAt(now: now()) {
            throw dashboardRefusal("The dashboard was updated less than 5 minutes ago. "
                                   + "Update now works again from \(DashboardWords.time(ready)).")
        }
        if let workflowID = state.workflowID, let workflow = workflow(workflowID, in: project) {
            if let refusal = await fire(workflow, on: .schedule(WorkflowSchedule()), byHand: true) {
                throw dashboardRefusal("\(workflow.name) did not start: \(refusal.message).")
            }
        } else {
            try await startDashboardUpdater(in: project)
        }
        dashboardChanged(project)
        return dashboardUpdate(project)
    }

    /// The one-off agent, on the project's default runtime, labelled `dashboard` so the page
    /// hears it start and end. Claimed before the start is awaited, so a second press while
    /// the runtime starts is refused rather than starting a second.
    private func startDashboardUpdater(in project: URL) async throws {
        var state = dashboardStore.state(project)
        state.updater = .init(agentID: nil, startedAt: now())
        dashboardStore.save(state, for: project)
        do {
            var start = try await startRequest(settings: WorkflowSettings(), folder: project,
                                               prompt: DashboardUpdate.oneOffPrompt, managesAgents: false)
            start.labels = [DashboardUpdate.label]
            let agentID = try await self.start(start, startedBy: nil, labelOwner: .agent)
            if var agent = agents[agentID] {
                agent.title = DashboardUpdate.oneOffTitle
                changed(agent)
            }
            state = dashboardStore.state(project)
            state.updater?.agentID = agentID
            dashboardStore.save(state, for: project)
        } catch {
            state = dashboardStore.state(project)
            state.updater = nil
            dashboardStore.save(state, for: project)
            throw error
        }
    }

    /// An agent labelled `dashboard` changed state: its project's page redraws Update now.
    func dashboardUpdaterMoved(_ agent: Agent, from before: Agent?) {
        guard before?.state != agent.state || before?.report != agent.report,
              agent.labels.contains(where: { $0.normalizedValue == DashboardUpdate.label }) else { return }
        dashboardChanged(agent.projectFolder)
    }
}
