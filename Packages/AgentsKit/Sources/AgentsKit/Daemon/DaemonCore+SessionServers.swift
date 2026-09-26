import AgentsKitCore
import Foundation

/// The MCP servers a session is made with (054, research R10, R11), as a plan a test can
/// read: what goes, in what order, and what was left out and why.
public struct SessionServers: Equatable, Sendable {
    public enum Drop: Equatable, Sendable {
        /// An earlier server has the name (FR-020).
        case nameTaken
        /// The runtime's handshake does not say it takes this transport (FR-019).
        case transportNotAdvertised(String)
        /// `mcp.json` could not be read, so none of the person's servers go.
        case mcpFileProblem
    }

    public var servers: [MCPServer]
    public var dropped: [(name: String, reason: Drop)]

    public static func == (a: SessionServers, b: SessionServers) -> Bool {
        a.servers == b.servers && a.dropped.map(\.name) == b.dropped.map(\.name)
            && a.dropped.map(\.reason) == b.dropped.map(\.reason)
    }

    /// R10 steps 1 to 3. The app's own first, then the agent's chosen servers, then the
    /// person's, then (Grok only) the ones inside the person's plugins. The first of a
    /// name is kept. An http or sse server the handshake does not advertise is left out.
    public static func plan(app: MCPServer, chosen: [MCPServer],
                            personal: Result<[MCPServer], PersonalDotAgents.MCPFileProblem>,
                            pluginServers: [MCPServer] = [],
                            http: Bool, sse: Bool) -> SessionServers {
        var plan = SessionServers(servers: [], dropped: [])
        let mine: [MCPServer]
        switch personal {
        case .success(let servers): mine = servers
        case .failure: mine = []; plan.dropped.append((PersonalDotAgents.mcpFile, .mcpFileProblem))
        }
        var names = Set<String>()
        for server in [app] + chosen + mine + pluginServers {
            switch server.transport {
            case .http where !http:
                plan.dropped.append((server.name, .transportNotAdvertised("http")))
                continue
            case .sse where !sse:
                plan.dropped.append((server.name, .transportNotAdvertised("sse")))
                continue
            default: break
            }
            guard names.insert(server.name).inserted else {
                plan.dropped.append((server.name, .nameTaken))
                continue
            }
            plan.servers.append(server)
        }
        return plan
    }
}

extension DaemonCore {
    /// Every server a session is made with, for both places one is made: a new agent
    /// (or draft, or workflow start) and an agent picked back up. `mcp.json` is read
    /// here, every time, so an edit reaches the next session without a restart, and
    /// nothing read from it is kept (R10, FR-023).
    func sessionServers(runtimeID: String, chosen: [MCPServer], token: String, managesAgents: Bool,
                        cwd: URL, capabilities: ACP.MCPCapabilities?,
                        pluginServers: [MCPServer] = []) async -> [MCPServer] {
        let personal = locations.personalHome.map { PersonalDotAgents.personalServers(home: $0) } ?? .success([])
        if case .failure(let problem) = personal {
            DaemonLog.shared.write("personal servers: left out, \(problem.message)"
                                   + (problem.line.map { " (line \($0))" } ?? ""))
        }
        let plan = SessionServers.plan(app: appServer(token: token, managesAgents: managesAgents),
                                       chosen: chosen, personal: personal, pluginServers: pluginServers,
                                       http: capabilities?.http ?? false, sse: capabilities?.sse ?? false)
        for (name, reason) in plan.dropped where reason != .mcpFileProblem {
            DaemonLog.shared.write("session servers: \(name) left out of a \(runtimeID) session: \(reason)")
        }
        return await bridged(plan.servers, runtimeID: runtimeID, token: token, cwd: cwd)
    }

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
