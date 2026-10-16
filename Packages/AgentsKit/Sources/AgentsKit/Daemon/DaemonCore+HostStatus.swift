import AgentsKitCore
import Foundation

extension DaemonCore {
    /// Whether this host is idle, as a workspace's stop when idle counts it (#691 US4, FR-030):
    /// no turn in flight, no agent waiting on a person, and no terminal or project shell open.
    ///
    /// Not `hasWorkInFlight`, which leaves out an agent waiting on a question, nor
    /// `isHoldingAgents`, which counts a warm runtime and a draft: stopping the machine under
    /// an unanswered question loses it, and a draft is nobody's work.
    func hostStatus() -> DaemonAPI.HostStatus {
        let working = agents.live.values.filter { [.starting, .running, .waitingOnUser].contains($0.state) }
        let running = working.map { agent in
            let runtime = RuntimeCatalog.runtime(id: agent.runtimeID)?.name ?? agent.runtimeID
            return agent.title.map { "\(runtime) (\($0))" } ?? runtime
        }.sorted()
        let idle = working.isEmpty && pendingPermissions.isEmpty && shells.openCount == 0
        return DaemonAPI.HostStatus(idle: idle, running: running, schedule: nextScheduled(after: now()))
    }

    /// This host's next scheduled workflow, for the control plane's wake-up call (#1004
    /// FR-002): the soonest due of the ones that run here and could fire, as their pages say.
    /// Only workflows with a schedule are looked at closer, so the 15-second tick reads no
    /// file it doesn't need (a digest is kept by its file's stamp).
    func nextScheduled(after date: Date) -> DaemonAPI.HostSchedule {
        var candidates: [(Date, Workflow)] = []
        for byID in workflows.values {
            for workflow in byID.values where !workflow.schedules.isEmpty && !workflow.isArchived && !workflow.isOff
                && workflow.runs(on: MachineID.current) {
                if let due = workflow.nextDue(after: date) { candidates.append((due, workflow)) }
            }
        }
        guard !candidates.isEmpty else { return DaemonAPI.HostSchedule() }
        let records = workflowStore.load()
        var ceilings: WorkflowCeilings?
        for (due, workflow) in candidates.sorted(by: { ($0.0, $0.1.name) < ($1.0, $1.1.name) }) {
            let state = records.state(folder: workflow.folder, workflowID: workflow.workflowID)
            guard awaitingApproval(workflow, state: state, records: records) == nil,
                  deniedHere(workflow, state: state) == nil else { continue }
            if ceilings == nil { ceilings = workflowCeilings(records: records) }
            guard limitReached(by: workflow, records: records, ceilings: ceilings) == nil else { continue }
            return DaemonAPI.HostSchedule(at: due, workflow: workflow.name)
        }
        return DaemonAPI.HostSchedule()
    }

    /// Says `host/status` when it has changed: on the 15-second tick, and when the uplink
    /// comes back. The next scheduled workflow changes it when one fires or is changed. A turn starting is heard within the tick, well inside any idle time.
    func reviseHostStatus() {
        reviseWaiting()
        guard let tellStatus else { return }
        let now = hostStatus()
        guard now != toldStatus, let params = try? JSONValue.encoding(now) else { return }
        toldStatus = now
        tellStatus(params)
    }
}
