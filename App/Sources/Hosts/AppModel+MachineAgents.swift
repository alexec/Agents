import AgentsKitCore
import Foundation

/// A machine page's Agent Loops section (#5273): asked of the control plane.
extension AppModel {
    /// `machines/agents` for a machine, or nil when there is no control plane to ask.
    var machineAgentsReader: (@MainActor (MachineRef) async throws -> DaemonAPI.MachineAgents)? {
        guard let control = controlRequests else { return nil }
        return { host in
            try await control.call(DaemonAPI.Method.machinesAgents, DaemonAPI.MachineRequest(host: host),
                                   returning: DaemonAPI.MachineAgents.self)
        }
    }

    /// `machines/agentsChanges`: the changes from one version to another.
    func agentsChanges(_ request: DaemonAPI.AgentsChangesRequest) async throws -> DaemonAPI.AgentsChanges {
        guard let control = controlRequests else { throw CancellationError() }
        return try await control.call(DaemonAPI.Method.machinesAgentsChanges, request, returning: DaemonAPI.AgentsChanges.self)
    }
}
