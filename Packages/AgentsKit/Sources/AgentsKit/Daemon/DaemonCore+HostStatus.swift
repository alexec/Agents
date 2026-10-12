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
        return DaemonAPI.HostStatus(idle: idle, running: running)
    }

    /// Says `host/status` when it has changed: on the 15-second tick, and when the uplink
    /// comes back. A turn starting is heard within the tick, well inside any idle time.
    func reviseHostStatus() {
        guard let tellStatus else { return }
        let now = hostStatus()
        guard now != toldStatus, let params = try? JSONValue.encoding(now) else { return }
        toldStatus = now
        tellStatus(params)
    }
}
