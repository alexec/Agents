import AgentsKitCore
import Foundation

/// The host's memory of its servers' health (#753). In the core, because only an actor's
/// stored properties can hold it; reached only from `DaemonCore+MCPHealth.swift`.
struct MCPHealthBook {
    /// A server's last check, for the entry it was made with.
    struct Result: Sendable {
        /// The entry as checked, secrets and sign-in filled: a change checks it again.
        var digest: String
        var check: DaemonAPI.MCPCheckState
        var at: Date
        var error: String?
        var tools: Int?
    }

    var started = false
    var results: [String: Result] = [:]
    /// Checks under way, by server id.
    var running: Set<String> = []
    /// Servers Check Now asked for, until their check starts.
    var forced: Set<String> = []
    /// What the clients were last told, so an unchanged pass tells them nothing.
    var told: DaemonAPI.MCPHealthSnapshot?
    var reconciling = false
    var reconcileAgain = false
    var ticker: Task<Void, Never>?
    /// How long a check waits for `initialize` and `tools/list`. A test shortens it.
    var timeout: Duration = .seconds(60)
}

/// Every MCP server in the host's `mcp.json` files and how each is doing (#753).
///
/// A hosted server (#488) says what its one copy is doing, and is never checked: that
/// would be a second copy. Any other is checked as a session would reach it, through the
/// daemon's own `MCPClient` as Verify (#305) does: started or connected, `initialize`, then
/// `tools/list`, then ended. When: as the daemon starts, when its entry changes (the files
/// are read once a minute, and at once after the app writes one), every four hours, and
/// on Check Now. A project's server not yet approved here, and one missing a secret, are
/// never started (Alex, #753 Decided).
///
/// Logged: the server's name and the outcome in a word, as the client logs it. Never a
/// command, argument, environment value, header, URL or body (054 FR-023).
extension DaemonCore {
    /// A server's answer is good for this long: the availability check's interval.
    static let mcpHealthInterval: TimeInterval = 4 * 60 * 60
    /// Checks at once: a stdio check starts a process.
    static let mcpHealthParallel = 3

    /// Begin checking. Once, as the daemon starts.
    func startMCPHealth() async {
        guard !mcpHealth.started else { return }
        mcpHealth.started = true
        mcpHealth.ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { return }
                await self?.reconcileMCPHealth()
            }
        }
        await reconcileMCPHealth()
    }

    func stopMCPHealth() {
        mcpHealth.started = false
        mcpHealth.ticker?.cancel()
        mcpHealth.ticker = nil
    }

    /// For a test: a shorter wait for a check.
    func setMCPHealth(timeout: Duration) { mcpHealth.timeout = timeout }

    /// Look again soon: the app wrote an `mcp.json`, or a hosted server changed state.
    func scheduleMCPHealthReconcile() {
        guard mcpHealth.started else { return }
        Task { [weak self] in await self?.reconcileMCPHealth() }
    }

    /// `mcp/health`: what the clients were last told, or a fresh look when nothing was.
    func mcpHealthSnapshot() async -> DaemonAPI.MCPHealthSnapshot {
        if let told = mcpHealth.told { return told }
        return await mcpHealthPass(starting: false)
    }

    /// `mcp/health/check`: Check Now on one file's servers.
    func mcpHealthCheck(_ request: DaemonAPI.MCPHealthCheckRequest) async -> DaemonAPI.MCPHealthSnapshot {
        let snapshot = await mcpHealthPass(starting: false)
        for server in snapshot.servers where server.project == request.project && !server.hosted {
            mcpHealth.forced.insert(server.id)
        }
        DaemonLog.shared.write("mcp health: check now (\(request.project == nil ? "personal" : "project"))")
        await reconcileMCPHealth()
        return mcpHealth.told ?? snapshot
    }

    func reconcileMCPHealth() async {
        if mcpHealth.reconciling {
            mcpHealth.reconcileAgain = true
            return
        }
        mcpHealth.reconciling = true
        repeat {
            mcpHealth.reconcileAgain = false
            let snapshot = await mcpHealthPass(starting: mcpHealth.started)
            var unstamped = snapshot
            unstamped.at = .distantPast
            var last = mcpHealth.told
            last?.at = .distantPast
            mcpHealth.told = snapshot
            if unstamped != last { broadcast(DaemonAPI.Notification.mcpHealthChanged, snapshot) }
        } while mcpHealth.reconcileAgain
        mcpHealth.reconciling = false
    }

    /// One look at every file: the rows, and with `starting`, the checks that are due.
    private func mcpHealthPass(starting: Bool) async -> DaemonAPI.MCPHealthSnapshot {
        let at = now()
        var rows: [DaemonAPI.MCPServerHealth] = []
        var problems: [DaemonAPI.MCPHealthFileProblem] = []
        var due: [Due] = []
        let live = Dictionary(await hostedServers.snapshot().servers.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let secrets: SecretsEnv = locations.personalHome.map { SecretsEnv.load(from: SecretsEnv.url(home: $0)) }
            ?? SecretsEnv(lines: [])

        if let home = locations.personalHome {
            let url = PersonalDotAgents.mcpURL(home: home)
            let found = await mcpHealthFile(PersonalDotAgents.personalServers(home: home), at: url, project: nil,
                                            cwd: home, now: at, live: live, secrets: secrets)
            rows += found.rows; due += found.due
            if let problem = found.problem { problems.append(problem) }
        }
        let folders = allProjects(includeArchived: false).map { Project.standardize($0.project.folder) }
            .sorted { $0.path < $1.path }
        for folder in folders {
            let url = MCPJSONFile.projectURL(folder: folder)
            let found = await mcpHealthFile(PersonalDotAgents.projectServers(in: folder), at: url, project: folder,
                                            cwd: folder, now: at, live: live, secrets: secrets)
            rows += found.rows; due += found.due
            if let problem = found.problem { problems.append(problem) }
        }

        // Forget what is no longer listed.
        let listed = Set(rows.map(\.id))
        mcpHealth.results = mcpHealth.results.filter { listed.contains($0.key) }
        mcpHealth.forced.formIntersection(listed)

        if starting {
            for item in due where mcpHealth.running.count < Self.mcpHealthParallel {
                mcpHealth.running.insert(item.id)
                mcpHealth.forced.remove(item.id)
                if let index = rows.firstIndex(where: { $0.id == item.id }) { rows[index].check = .checking }
                let timeout = mcpHealth.timeout
                Task { [weak self] in
                    await self?.checkMCPServer(id: item.id, server: item.server, cwd: item.cwd,
                                               digest: item.digest, timeout: timeout)
                }
            }
        }
        return DaemonAPI.MCPHealthSnapshot(servers: rows, problems: problems, at: at)
    }

    private typealias Due = (id: String, server: MCPServer, cwd: URL, digest: String)

    /// One `mcp.json`'s rows, its problem, and its checks that are due.
    private func mcpHealthFile(_ found: Result<[MCPServer], PersonalDotAgents.MCPFileProblem>, at url: URL,
                               project: URL?, cwd: URL, now at: Date, live: [String: DaemonAPI.HostedMCPStatus],
                               secrets: SecretsEnv)
        async -> (rows: [DaemonAPI.MCPServerHealth], problem: DaemonAPI.MCPHealthFileProblem?, due: [Due]) {
        var rows: [DaemonAPI.MCPServerHealth] = []
        var due: [Due] = []
        let path = project?.path(percentEncoded: false)
        let servers: [MCPServer]
        switch found {
        case .success(let listed): servers = listed
        case .failure(let problem):
            return ([], .init(project: path, message: problem.message + (problem.line.map { " (line \($0))" } ?? "")),
                    [])
        }
        guard !servers.isEmpty else { return ([], nil, []) }
        let hostedNames = PersonalDotAgents.hostedNames(at: url)
        let approvals = project.map { _ in mcpApprovalStore.load() }
        let root = project.flatMap { _ in try? MCPJSONFile.loadOrEmpty(at: url) }
        for server in servers {
            var row = DaemonAPI.MCPServerHealth(name: server.name, project: path,
                                                transport: Self.transportName(server.transport),
                                                hosted: hostedNames.contains(server.name))
            if row.hosted {
                row.live = live[row.id]
                rows.append(row)
                continue
            }
            if case .sse = server.transport {
                row.check = .oldTransport
            } else if let project, let approvals,
                      !Self.approved(server.name, in: project, root: root, approvals: approvals) {
                row.check = .waiting
            } else if var filled = secrets.filled(server) {
                var signIn = false
                if case .http(let url, var headers) = filled.transport, !MCPSignIns.bringsOwnAuthorization(headers) {
                    switch await mcpSignIns.bearer(server: url, name: server.name) {
                    case .none: break
                    case .token(let token):
                        headers["Authorization"] = "Bearer \(token)"
                        filled = MCPServer(name: filled.name, transport: .http(url: url, headers: headers))
                    case .needsSignIn: signIn = true
                    }
                }
                if signIn {
                    row.check = .signIn
                } else {
                    let digest = ServerViewCatalog.key(for: filled)
                    let kept = mcpHealth.results[row.id].flatMap { $0.digest == digest ? $0 : nil }
                    if let kept {
                        row.check = kept.check; row.checkedAt = kept.at
                        row.lastError = kept.error; row.tools = kept.tools
                    }
                    if mcpHealth.running.contains(row.id) {
                        row.check = .checking
                    } else if mcpHealth.forced.contains(row.id)
                                || kept.map({ at >= $0.at.addingTimeInterval(Self.mcpHealthInterval) }) ?? true {
                        due.append((row.id, filled, cwd, digest))
                    }
                }
            } else {
                row.check = .missingSecret
            }
            rows.append(row)
        }
        return (rows, nil, due)
    }

    /// One check: connect, `initialize`, `tools/list`, end.
    private func checkMCPServer(id: String, server: MCPServer, cwd: URL, digest: String, timeout: Duration) async {
        let client = MCPClient(server: server, cwd: cwd, timeout: timeout, http: mcpVerifyHTTP)
        var result = MCPHealthBook.Result(digest: digest, check: .failed, at: now())
        do {
            try await client.connect()
            let tools = try await client.listTools()
            result.check = .answered
            result.tools = tools.count
        } catch MCPClient.Failure.authRequired(let metadata) {
            if case .http(let url, let headers) = server.transport, !MCPSignIns.bringsOwnAuthorization(headers) {
                await mcpSignIns.markNeedsSignIn(server: url, name: server.name, resourceMetadata: metadata)
                result.check = .signIn
            } else {
                result.error = "It refused the Authorization header it was sent (HTTP 401)."
            }
        } catch let failure as MCPClient.Failure {
            result.error = MCPHandEntry.sentence(failure, timeout: Int(timeout.components.seconds))
        } catch {
            result.error = "It could not be reached."
        }
        await client.end()
        result.at = now()
        DaemonLog.shared.write("mcp health: \(server.name) → \(result.check.rawValue)")
        mcpHealth.running.remove(id)
        mcpHealth.results[id] = result
        await reconcileMCPHealth()
    }

    /// A project's entry, approved here as it is written now.
    private static func approved(_ name: String, in project: URL, root: OrderedJSON?, approvals: MCPApprovals) -> Bool {
        guard let entry = root?["mcpServers"]?[name] else { return false }
        return approvals.isApproved(folder: project, name: name, entry: entry)
    }

    static func transportName(_ transport: MCPServer.Transport) -> DaemonAPI.MCPTransportName {
        switch transport {
        case .stdio: .stdio
        case .http: .http
        case .sse: .sse
        }
    }
}
