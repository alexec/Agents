import AgentsKitCore
import Foundation

/// A machine page's Agent Loops section (#5273), as the window's: asked of the control plane.
extension RemoteModel {
    /// `machines/agents` for a machine, or nil when there is no control plane to ask. The home
    /// Mac is `.mac` here and the control plane's home host there.
    var machineAgentsReader: (@MainActor (MachineRef) async throws -> DaemonAPI.MachineAgents)? {
        guard let control = controlPlane else { return nil }
        let home = controlHome
        return { host in
            let asked = host == .mac ? (home ?? .mac) : host
            return try await control.call(DaemonAPI.Method.machinesAgents, DaemonAPI.MachineRequest(host: asked),
                                          returning: DaemonAPI.MachineAgents.self)
        }
    }

    /// `machines/agentsChanges`: the changes from one version to another.
    func agentsChanges(_ request: DaemonAPI.AgentsChangesRequest) async throws -> DaemonAPI.AgentsChanges {
        guard let control = controlPlane else { throw CancellationError() }
        return try await control.call(DaemonAPI.Method.machinesAgentsChanges, request, returning: DaemonAPI.AgentsChanges.self)
    }
}
