import AgentsKitCore
import Foundation

/// MCP servers the daemon hosts (#488): an entry with `"hosted": true` runs once on this
/// host, and every session and event subscription that names it shares that copy
/// (`HostedMCPServers`).
extension DaemonCore {
    /// Tell every client when a hosted server's status changes, and the events source when
    /// one says its events changed. Once, as the daemon starts.
    func startHostedServers() async {
        await hostedServers.onChange { [weak self] in
            Task { await self?.hostedServersChanged() }
        }
        await hostedServers.onNotification { [weak self] key, method in
            guard method == MCPEventsWire.listChanged else { return }
            Task { await self?.hostedServerListChanged(key) }
        }
    }

    private func hostedServersChanged() async {
        broadcast(DaemonAPI.Notification.mcpHostedChanged, await hostedServers.snapshot())
    }

    /// `server`, hosted, as `user` is handed it: an http server on the app's endpoint with
    /// `user` as its bearer. Nil when it is not hosted.
    func hostedRoute(_ server: ViewServer, user: String) async throws -> MCPServer? {
        guard server.hosted, case .stdio = server.filled.transport else { return nil }
        let port = try await appTools.start()
        let path = try await hostedServers.use(server.filled, key: server.poolKey, project: server.project,
                                               cwd: server.cwd, user: user)
        return AppToolsEndpoint.hostedServer(name: server.name, port: port, path: path, token: user)
    }

    /// A session's servers with each hosted one swapped for its route, the session's token
    /// as the bearer. One the host has no room for (`HostedMCPServers.limit`) goes as it
    /// is, so the runtime runs its own copy: the agent still has its tools.
    func hostedSwapped(_ servers: [MCPServer], project: URL, token: String, runtimeID: String) async -> [MCPServer] {
        var swapped: [MCPServer] = []
        for server in servers {
            guard case .stdio = server.transport,
                  case .success(let resolved) = mcpServer(server.name, project: project, allowing: [.stdio]),
                  resolved.hosted, resolved.filled == server else {
                swapped.append(server)
                continue
            }
            do {
                swapped.append(try await hostedRoute(resolved, user: token) ?? server)
            } catch HostedMCPServers.Refusal.tooMany {
                DaemonLog.shared.write("hosted mcp: \(server.name) runs in the \(runtimeID) session itself: "
                                       + "\(HostedMCPServers.limit) hosted servers are in use")
                swapped.append(server)
            } catch {
                DaemonLog.shared.write("hosted mcp: \(server.name) runs in the \(runtimeID) session itself: "
                                       + "the endpoint could not start")
                swapped.append(server)
            }
        }
        return swapped
    }
}
