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
        /// A `${NAME}` in the entry was not in `secrets.env` (060).
        case missingSecret
    }

    public var servers: [MCPServer]
    public var dropped: [(name: String, reason: Drop)]

    public static func == (a: SessionServers, b: SessionServers) -> Bool {
        a.servers == b.servers && a.dropped.map(\.name) == b.dropped.map(\.name)
            && a.dropped.map(\.reason) == b.dropped.map(\.reason)
    }

    /// The app's own first, then the agent's chosen servers, then the project's approved
    /// ones, then the person's, then (Grok only) the ones inside the person's plugins
    /// (060, R6). The first of a name is kept. An http or sse server the handshake does
    /// not advertise is left out, except the app's own, which is never left out (#185):
    /// `sessionServers` refuses the session instead.
    public static func plan(app: MCPServer, chosen: [MCPServer],
                            project: [MCPServer] = [],
                            personal: Result<[MCPServer], PersonalDotAgents.MCPFileProblem>,
                            pluginServers: [MCPServer] = [],
                            http: Bool, sse: Bool) -> SessionServers {
        var plan = SessionServers(servers: [], dropped: [])
        let mine: [MCPServer]
        switch personal {
        case .success(let servers): mine = servers
        case .failure: mine = []; plan.dropped.append((PersonalDotAgents.mcpFile, .mcpFileProblem))
        }
        var names: Set<String> = [app.name]
        plan.servers.append(app)
        for server in chosen + project + mine + pluginServers {
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

    /// Fill `${NAME}` from `secrets.env`. A server that still has a missing name is left
    /// out, with the names it needed.
    static func fillSecrets(_ servers: [MCPServer], with secrets: SecretsEnv)
        -> (filled: [MCPServer], missing: [(name: String, secrets: [String])]) {
        var filled: [MCPServer] = []
        var missing: [(name: String, secrets: [String])] = []
        for server in servers {
            if let done = secrets.filled(server) {
                filled.append(done)
            } else {
                let names = SecretsEnv.referencedNames(in: server).filter { secrets.value(of: $0) == nil }
                var seen = Set<String>()
                missing.append((server.name, names.filter { seen.insert($0).inserted }))
            }
        }
        return (filled, missing)
    }

    /// Project servers a session may be given: approved entries, with secrets filled.
    /// Unapproved names are `waiting`. Unfilled ones are `missing` and not in `servers`.
    static func projectContribution(in folder: URL, approvals: MCPApprovals, secrets: SecretsEnv)
        -> (servers: [MCPServer], waiting: [String], missing: [(name: String, secrets: [String])],
            unreadable: PersonalDotAgents.MCPFileProblem?) {
        switch PersonalDotAgents.projectServers(in: folder) {
        case .failure(let problem):
            return ([], [], [], problem)
        case .success(let all):
            let root = try? MCPJSONFile.loadOrEmpty(at: MCPJSONFile.projectURL(folder: folder))
            var kept: [MCPServer] = []
            var waiting: [String] = []
            for server in all {
                guard let entry = root?["mcpServers"]?[server.name] else { continue }
                if approvals.isApproved(folder: folder, name: server.name, entry: entry) {
                    kept.append(server)
                } else {
                    waiting.append(server.name)
                }
            }
            let (filled, missing) = fillSecrets(kept, with: secrets)
            return (filled, waiting, missing, nil)
        }
    }
}

extension DaemonCore {
    /// Every server a session is made with, for both places one is made: a new agent
    /// (or draft, or workflow start) and an agent picked back up. `mcp.json` is read
    /// here, every time, so an edit reaches the next session without a restart, and
    /// nothing read from it is kept (R10, FR-023).
    func sessionServers(runtimeID: String, chosen: [MCPServer], token: String, managesAgents: Bool,
                        cwd: URL, capabilities: ACP.MCPCapabilities?) async throws -> [MCPServer] {
        // The app's tools are served over http and nothing else (#185). A runtime that does
        // not take it would run with none of them, which is worse than not running.
        guard capabilities?.http == true else {
            DaemonLog.shared.write("session servers: \(runtimeID) does not take http MCP servers; refused")
            throw JSONRPCError(code: JSONRPCError.internalError,
                               message: Self.noHTTPRefusal(RuntimeCatalog.runtime(id: runtimeID)?.name ?? runtimeID))
        }
        let personalRaw = locations.personalHome.map { PersonalDotAgents.personalServers(home: $0) } ?? .success([])
        let secrets: SecretsEnv = {
            guard let home = locations.personalHome else { return SecretsEnv(lines: []) }
            return SecretsEnv.load(from: SecretsEnv.url(home: home))
        }()
        let personal: Result<[MCPServer], PersonalDotAgents.MCPFileProblem>
        switch personalRaw {
        case .failure(let problem):
            personal = .failure(problem)
        case .success(let servers):
            let (filled, missing) = SessionServers.fillSecrets(servers, with: secrets)
            for item in missing { Self.logMissingSecret(item) }
            personal = .success(filled)
        }
        let projectFolder = Project.standardize(cwd)
        let contribution = SessionServers.projectContribution(
            in: projectFolder, approvals: mcpApprovalStore.load(), secrets: secrets)
        for name in contribution.waiting {
            DaemonLog.shared.write("session servers: \(name) left out: waiting for approval")
        }
        for item in contribution.missing { Self.logMissingSecret(item) }
        if let problem = contribution.unreadable {
            DaemonLog.shared.write("project servers: left out, \(problem.message)"
                                   + (problem.line.map { " (line \($0))" } ?? ""))
        }
        // Grok loads a plugin's skills and commands from `pluginDirs` but never starts its
        // servers, so they go here too (R9, R12).
        var pluginServers: [MCPServer] = []
        if PersonalDotAgents.rule(for: runtimeID)?.pluginHandover == .sessionMetaWithServers, let home = locations.personalHome {
            let raw = PersonalDotAgents.personalPluginServers(home: home)
            let (filled, missing) = SessionServers.fillSecrets(raw, with: secrets)
            for item in missing { Self.logMissingSecret(item) }
            pluginServers = filled
        }
        if case .failure(let problem) = personal {
            DaemonLog.shared.write("personal servers: left out, \(problem.message)"
                                   + (problem.line.map { " (line \($0))" } ?? ""))
        }
        // Without the tools for moving folders for a runtime that forgets its conversation
        // in another folder (053).
        let app = try await appServer(token: token, managesAgents: managesAgents,
                                      movesItself: RuntimeCatalog.canMoveFolders(runtimeID: runtimeID))
        let plan = SessionServers.plan(app: app, chosen: chosen, project: contribution.servers,
                                       personal: personal, pluginServers: pluginServers,
                                       http: capabilities?.http ?? false, sse: capabilities?.sse ?? false)
        for (name, reason) in plan.dropped where reason != .mcpFileProblem {
            DaemonLog.shared.write("session servers: \(name) left out of a \(runtimeID) session: \(reason)")
        }
        return await bridged(plan.servers, runtimeID: runtimeID, token: token, cwd: cwd)
    }

    static func noHTTPRefusal(_ runtime: String) -> String {
        "\(runtime) doesn't say it takes MCP servers over http, so its agents would have none of the app's "
            + "tools. Update \(runtime), or pick another runtime."
    }

    private static func logMissingSecret(_ item: (name: String, secrets: [String])) {
        let names = item.secrets.isEmpty ? "" : " \(item.secrets.joined(separator: ", "))"
        DaemonLog.shared.write("session servers: \(item.name) left out: missing secret\(names)")
    }

    /// For a runtime that takes no stdio server from the client (Copilot, research R9),
    /// each stdio server is swapped for a route on the bridge, which runs it and serves it
    /// over loopback http. Every other runtime gets the list as it is.
    ///
    /// The app's own `agents` server is http already (#185), so it goes through as it is;
    /// only the person's stdio servers are bridged. A server the bridge cannot stand in for
    /// is left out and logged by name; the session is still made.
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

    /// End the routes a session's token was given, when that token stops speaking for anyone.
    func endBridgeRoutes(for token: String) {
        #if canImport(Network) && canImport(Security)
        bridge.endRoutes(for: token)
        #endif
    }
}
