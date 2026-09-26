import AgentsKitCore
import Foundation

/// The MCP servers a session is made with (054, research R10, R11).
extension DaemonCore {
    /// For a runtime that takes no stdio server from the client (Copilot, research R9),
    /// each stdio server is swapped for a route on the bridge, which runs it and serves it
    /// over loopback http. Every other runtime gets the list as it is.
    ///
    /// The app's own `agents` server is in the list too, so this is what gives a Copilot
    /// agent the app's tools. A server the bridge cannot stand in for is left out and
    /// logged by name; the session is still made.
    func bridged(_ servers: [MCPServer], runtimeID: String, token: String, cwd: URL) async -> [MCPServer] {
        guard PersonalDotAgents.rule(for: runtimeID)?.takesStdioServers == false else { return servers }
        #if canImport(Network) && canImport(Security)
        var bridged: [MCPServer] = []
        for server in servers {
            do {
                bridged.append(try await bridge.route(for: server, token: token, cwd: cwd))
            } catch {
                DaemonLog.shared.write("bridge: \(server.name) left out of a \(runtimeID) session: \(error)")
            }
        }
        return bridged
        #else
        return servers
        #endif
    }

    /// Whether `peer` is a server the bridge started for one of `token`'s routes.
    func isBridged(_ peer: Int32, token: String) -> Bool {
        #if canImport(Network) && canImport(Security)
        bridge.processIdentifiers(for: token).contains { PeerCredentials.descends(peer, from: $0) }
        #else
        false
        #endif
    }

    /// End the routes a session's token was given, when that token stops speaking for anyone.
    func endBridgeRoutes(for token: String) {
        #if canImport(Network) && canImport(Security)
        bridge.endRoutes(for: token)
        #endif
    }
}
