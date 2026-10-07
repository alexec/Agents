import AgentsKitCore
import Foundation

/// Views from people's own MCP servers (#191): the app as an MCP client.
///
/// A runtime connects to the person's servers itself, and no runtime says a tool has a
/// view (#186). So the daemon reads the call from the runtime's ACP updates by its shape
/// (`ACPToolShape`), checks the server's own catalog of views (`ServerViewCatalog`), and
/// writes an `appView` entry as it does for the `agents` server. What the drawn view asks
/// for — its resource, a tool only a view may call — goes to the server over a connection
/// of the daemon's own (`MCPClientPool`), on the host that runs the project.
///
/// Only http servers, for now (Q5): a stdio server's views would need a second copy of
/// it, so they say so instead. A server waiting for approval, missing a secret, or wanting
/// a sign-in (#306) shows nothing. A new or changed view asks Show / Don't Show once (Q6:
/// personal servers too). Logged: names, `ui://` addresses, policies and words. Never a
/// command, URL, header, environment value or body (054 FR-023).
extension DaemonCore {
    /// A server a view may come from, set up and approved here.
    struct ViewServer: Sendable {
        var name: String
        /// The project's folder, `personal`, or a plugin's folder: where its entry is.
        var scope: String
        var filled: MCPServer
        var cwd: URL
        /// The catalog's key and the pool's: a digest of the entry as written.
        var entry: String

        var poolKey: MCPClientPool.Key { .init(scope: scope, name: name, entry: entry) }
    }

    /// Why a server's views are not shown here, in words for a person.
    enum ViewServerProblem: Error, Equatable {
        case notSetUp
        case waiting
        case localServer
        case oldTransport
        case missingSecret
        case signIn
        case unreachable(String)

        func words(_ server: String) -> String {
            switch self {
            case .notSetUp: "\(server) is not set up here."
            case .waiting: "\(server) is waiting for approval, so its views are not shown."
            case .localServer: "Views from local servers aren't shown yet: \(server) runs on this machine (stdio). "
                + "Only servers reached over http show their views."
            case .oldTransport: "\(server) uses the old sse transport, which can't show views."
            case .missingSecret: "\(server) needs a secret that isn't set here, so its views are not shown."
            case .signIn: "\(server) wants a sign-in first, so its views are not shown."
            case .unreachable(let why): "\(server) did not answer: \(why)"
            }
        }

        /// For a pin that can't be drawn here (`PinMissing`).
        var pinReason: String {
            switch self {
            case .notSetUp: PinMissing.serverNotSetUp
            case .waiting: PinMissing.waitingForApproval
            case .localServer: PinMissing.localServer
            case .oldTransport: PinMissing.localServer
            case .missingSecret: PinMissing.missingSecret
            case .signIn: PinMissing.signIn
            case .unreachable: PinMissing.serverNotSetUp
            }
        }
    }

    var viewCatalogStore: ServerViewCatalogStore {
        ServerViewCatalogStore(folder: locations.root.appending(path: "mcp-views", directoryHint: .isDirectory))
    }

    // MARK: Which server

    /// `name` as a session in `project` is given it: the project's approved entries, then
    /// the person's, then plugins' (the first of a name wins, as for sessions).
    func viewServer(_ name: String, project: URL) -> Result<ViewServer, ViewServerProblem> {
        guard name != AppTool.serverName else { return .failure(.notSetUp) }
        let folder = Project.standardize(project)
        let secrets: SecretsEnv = locations.personalHome.map { SecretsEnv.load(from: SecretsEnv.url(home: $0)) }
            ?? SecretsEnv(lines: [])
        func ready(_ server: MCPServer, scope: String, cwd: URL) -> Result<ViewServer, ViewServerProblem> {
            switch server.transport {
            case .stdio: return .failure(.localServer)
            case .sse: return .failure(.oldTransport)
            case .http: break
            }
            guard let filled = secrets.filled(server) else { return .failure(.missingSecret) }
            return .success(ViewServer(name: name, scope: scope, filled: filled, cwd: cwd,
                                       entry: ServerViewCatalog.key(for: server)))
        }
        if case .success(let servers) = PersonalDotAgents.projectServers(in: folder),
           let server = servers.first(where: { $0.name == name }) {
            let root = try? MCPJSONFile.loadOrEmpty(at: MCPJSONFile.projectURL(folder: folder))
            guard let entry = root?["mcpServers"]?[name],
                  mcpApprovalStore.load().isApproved(folder: folder, name: name, entry: entry) else {
                return .failure(.waiting)
            }
            return ready(server, scope: MCPApprovals.viewScope(folder), cwd: folder)
        }
        if let home = locations.personalHome, case .success(let servers) = PersonalDotAgents.personalServers(home: home),
           let server = servers.first(where: { $0.name == name }) {
            return ready(server, scope: MCPApprovals.viewScope(nil), cwd: home)
        }
        let records = pluginApprovalStore.load()
        for plugin in DotAgents.pluginFolders(for: folder) {
            guard let server = PersonalDotAgents.pluginServers(plugin).first(where: { $0.name == name }) else { continue }
            guard pluginAwaitingApproval(plugin, records: records) == nil else { return .failure(.waiting) }
            return ready(server, scope: Self.pluginKey(plugin), cwd: folder)
        }
        if let home = locations.personalHome {
            for plugin in PersonalDotAgents.personalPluginFolders(home: home) {
                guard let server = PersonalDotAgents.pluginServers(plugin).first(where: { $0.name == name }) else { continue }
                return ready(server, scope: Self.pluginKey(plugin), cwd: home)
            }
        }
        return .failure(.notSetUp)
    }

    /// Every server name a session in `project` could have been given, but the app's own.
    func viewServerNames(project: URL) -> [String] {
        let folder = Project.standardize(project)
        var names: [String] = []
        if case .success(let servers) = PersonalDotAgents.projectServers(in: folder) { names += servers.map(\.name) }
        if let home = locations.personalHome, case .success(let servers) = PersonalDotAgents.personalServers(home: home) {
            names += servers.map(\.name)
        }
        for plugin in DotAgents.pluginFolders(for: folder) { names += PersonalDotAgents.pluginServers(plugin).map(\.name) }
        if let home = locations.personalHome { names += PersonalDotAgents.personalPluginServers(home: home).map(\.name) }
        var seen: Set<String> = [AppTool.serverName]
        return names.filter { seen.insert($0).inserted }
    }

    // MARK: The catalog

    /// The server's views as last read, without connecting.
    func cachedViewCatalog(_ server: ViewServer) -> ServerViewCatalog? {
        if let held = viewCatalogs[server.entry], now().timeIntervalSince(held.madeAt) < ServerViewCatalog.freshFor {
            return held
        }
        guard let read = viewCatalogStore.load(server.entry, now: now()) else { return nil }
        keepCatalog(read, key: server.entry)
        return read
    }

    /// The server's views, read from it when none is kept. Nil when it could not be read;
    /// a server that failed is not asked again for a few minutes.
    func viewCatalog(_ server: ViewServer) async -> ServerViewCatalog? {
        if let kept = cachedViewCatalog(server) { return kept }
        if let failed = viewCatalogFailures[server.entry], now().timeIntervalSince(failed) < 300 { return nil }
        if let loading = viewCatalogLoads[server.entry] { return await loading.value }
        let pool = viewClients
        let name = server.name
        let at = now()
        let load = Task<ServerViewCatalog?, Never> {
            do {
                return try await pool.with(server.poolKey, server: server.filled, cwd: server.cwd) { client in
                    let tools = try await client.listTools()
                    let resources = try await client.listResources()
                    return ServerViewCatalog.make(server: name, tools: tools, resources: resources, now: at)
                }
            } catch let failure as MCPClient.Failure {
                DaemonLog.shared.write("mcp views: \(name)'s views could not be read (\(failure.logWord))")
                return nil
            } catch {
                DaemonLog.shared.write("mcp views: \(name)'s views could not be read")
                return nil
            }
        }
        viewCatalogLoads[server.entry] = load
        let catalog = await load.value
        viewCatalogLoads[server.entry] = nil
        if let catalog {
            viewCatalogStore.save(catalog, key: server.entry)
            keepCatalog(catalog, key: server.entry)
            viewCatalogFailures[server.entry] = nil
            DaemonLog.shared.write("mcp views: \(name) has \(catalog.tools.count) tool(s) with a view")
        } else {
            viewCatalogFailures[server.entry] = now()
        }
        return catalog
    }

    private func keepCatalog(_ catalog: ServerViewCatalog, key: String) {
        viewCatalogs[key] = catalog
        if viewCatalogs.count > 32, let oldest = viewCatalogs.min(by: { $0.value.madeAt < $1.value.madeAt })?.key {
            viewCatalogs.removeValue(forKey: oldest)
        }
    }

    // MARK: A call in a chat

    /// One call of a person's server's tool, as the runtime has told it so far.
    struct ThirdPartyCall: Sendable {
        var candidates: [ACPToolShape.Candidate]
        /// The view's id, made once, so the call's entries share it however they race.
        var viewID = UUID()
        var view: AppViewCall?
        var call: ToolCall
    }

    /// A tool call from the runtime: if it is a call of a person's server's tool with a
    /// view, its `appView` entry, written as it starts (when the runtime named the server
    /// outright) and again when it is answered. The app never calls the tool itself.
    func noteThirdPartyToolCall(_ kind: TranscriptEntry.Kind, agentID: UUID) {
        let incoming: ToolCall
        switch kind {
        case .toolCall(let call), .toolCallUpdate(let call): incoming = call
        default: return
        }
        guard let id = incoming.toolCallID, let agent = agents[agentID] else { return }
        var calls = thirdPartyCalls[agentID] ?? [:]
        var state: ThirdPartyCall
        if var known = calls[id] {
            known.call = Self.merged(known.call, incoming)
            state = known
        } else {
            let names = viewServerNames(project: agent.projectFolder)
            guard !names.isEmpty else { return }
            let candidates = ACPToolShape.candidates(incoming, servers: names)
            guard !candidates.isEmpty else { return }
            state = ThirdPartyCall(candidates: candidates, view: nil, call: incoming)
        }
        guard !state.candidates.isEmpty else { return }
        calls[id] = state
        // Bounded: the last few calls an agent made are all that can still be answered.
        if calls.count > 64, let first = calls.keys.sorted().first, first != id { calls.removeValue(forKey: first) }
        thirdPartyCalls[agentID] = calls
        let project = agent.projectFolder
        Task { await self.writeThirdPartyView(id, agentID: agentID, project: project) }
    }

    /// The later update over the earlier: a field it leaves out keeps what was there.
    private static func merged(_ old: ToolCall, _ new: ToolCall) -> ToolCall {
        var call = old
        if new.title != "Tool call" { call.title = new.title }
        call.name = new.name ?? old.name
        call.status = new.status ?? old.status
        call.rawInput = new.rawInput ?? old.rawInput
        call.rawOutput = new.rawOutput ?? old.rawOutput
        return call
    }

    private func writeThirdPartyView(_ id: String, agentID: UUID, project: URL) async {
        guard let first = thirdPartyCalls[agentID]?[id], !first.candidates.isEmpty else { return }
        // Which reading names a tool with a view, by the server's own catalog.
        var chosen: (candidate: ACPToolShape.Candidate, tool: ServerViewCatalog.Tool)?
        for candidate in first.candidates {
            guard case .success(let server) = viewServer(candidate.server, project: project),
                  let catalog = await viewCatalog(server), let tool = catalog.tool(candidate.tool) else { continue }
            chosen = (candidate, tool)
            break
        }
        // As it stands now: other updates may have come while the catalog was read.
        guard let latest = thirdPartyCalls[agentID]?[id] else { return }
        guard let (candidate, tool) = chosen else {
            thirdPartyCalls[agentID]?[id]?.candidates = []
            return
        }
        var view = latest.view ?? AppViewCall(id: latest.viewID, server: candidate.server, tool: tool.name,
                                              resourceURI: tool.resourceURI, arguments: candidate.arguments,
                                              pinnable: tool.feedsPins ? true : nil)
        if let result = ACPToolShape.result(latest.call) {
            // A text-only result is not drawn in the chat (Q7); a call already shown
            // running still gets its answer.
            guard result.drawable || latest.view != nil else {
                thirdPartyCalls[agentID]?[id]?.candidates = []
                DaemonLog.shared.write("mcp views: \(candidate.server)'s \(tool.name) answered in text only: not drawn inline")
                return
            }
            view.result = result.value
            view.state = .done
        } else {
            // A joined title is only trusted once there is a result to draw from, and a
            // call is shown running once.
            guard candidate.exact, latest.view == nil else { return }
        }
        guard view != latest.view, latest.view?.state != .done else { return }
        thirdPartyCalls[agentID]?[id]?.view = view
        thirdPartyViews[view.id] = (agentID, candidate.server)
        if thirdPartyViews.count > 512, let any = thirdPartyViews.keys.first(where: { $0 != view.id }) {
            thirdPartyViews.removeValue(forKey: any)
        }
        await record(.appView(view), for: agentID)
    }

    /// The server whose view `viewID` is in `agentID`'s chat: kept as it was written, or
    /// found in the record after a restart. Nil for the app's own views.
    func thirdPartyServer(ofView viewID: UUID, agentID: UUID) async -> String? {
        if let known = thirdPartyViews[viewID] {
            return known.agent == agentID && known.server != AppTool.serverName ? known.server : nil
        }
        guard agents[agentID] != nil,
              let page = try? await store.transcript(for: agentID, before: nil, limit: DaemonAPI.TranscriptRequest.limitCeiling)
        else { return nil }
        var server = AppTool.serverName
        for entry in page.entries.reversed() {
            if case .appView(let call) = entry.kind, call.id == viewID {
                server = call.server
                break
            }
        }
        // Kept either way, so the app's own views are looked up once.
        thirdPartyViews[viewID] = (agentID, server)
        if thirdPartyViews.count > 512, let any = thirdPartyViews.keys.first(where: { $0 != viewID }) {
            thirdPartyViews.removeValue(forKey: any)
        }
        return server == AppTool.serverName ? nil : server
    }

    // MARK: What its view asks for

    /// The project a view's request is for: its agent's, or the pin's.
    func viewProject(agentID: UUID, claimed: URL?) throws -> URL {
        if let agent = agents[agentID] {
            let project = Project.standardize(agent.projectFolder)
            if let claimed, Project.standardize(claimed) != project {
                throw JSONRPCError(code: DaemonAPI.Failure.viewRefused, message: "That view is outside its project.")
            }
            return project
        }
        if let claimed, isProject(Project.standardize(claimed)) { return Project.standardize(claimed) }
        throw JSONRPCError(code: DaemonAPI.Failure.noSuchAgent, message: "That view has no project.")
    }

    private func readyViewServer(_ name: String, project: URL) throws -> ViewServer {
        switch viewServer(name, project: project) {
        case .success(let server): return server
        case .failure(let problem):
            DaemonLog.shared.write("mcp views: \(name)'s view not shown: \(problem.pinReason)")
            throw JSONRPCError(code: DaemonAPI.Failure.viewRefused, message: problem.words(name))
        }
    }

    /// A call of the server, in words for the person when it fails.
    private func onServer<T: Sendable>(_ server: ViewServer,
                                       _ body: @Sendable (MCPClient) async throws -> T) async throws -> T {
        do {
            return try await viewClients.with(server.poolKey, server: server.filled, cwd: server.cwd, body)
        } catch MCPClient.Failure.authRequired {
            DaemonLog.shared.write("mcp views: \(server.name) wants a sign-in")
            throw JSONRPCError(code: DaemonAPI.Failure.viewRefused, message: ViewServerProblem.signIn.words(server.name))
        } catch let failure as MCPClient.Failure {
            DaemonLog.shared.write("mcp views: \(server.name) did not answer (\(failure.logWord))")
            let words: String
            switch failure {
            case .refused(_, let message) where !message.isEmpty: words = "\(server.name) refused: \(message.prefix(300))"
            default: words = ViewServerProblem.unreachable(MCPHandEntry.sentence(failure, timeout: 60)).words(server.name)
            }
            throw JSONRPCError(code: DaemonAPI.Failure.viewRefused, message: words)
        }
    }

    /// `resources/read` of a person's server's view, for drawing: only once the person has
    /// said Show to this version of it.
    func readThirdPartyView(_ request: DaemonAPI.ViewReadRequest, server name: String) async throws -> DaemonAPI.ViewResource {
        let project = try viewProject(agentID: request.agentID, claimed: request.project)
        let server = try readyViewServer(name, project: project)
        guard request.uri.hasPrefix("ui://") else {
            throw JSONRPCError(code: DaemonAPI.Failure.viewRefused, message: "Only a ui:// view can be drawn.")
        }
        let uri = request.uri
        let contents = try await onServer(server) { try await $0.readResource(uri) }
        guard let content = contents.first(where: { $0["uri"]?.stringValue == uri }) ?? contents.first else {
            throw JSONRPCError(code: DaemonAPI.Failure.viewRefused, message: "\(name) has no view at \(uri).")
        }
        let mimeType = content["mimeType"]?.stringValue ?? ""
        guard mimeType.lowercased().replacingOccurrences(of: " ", with: "") == AppViewResourceType.html else {
            throw JSONRPCError(code: DaemonAPI.Failure.viewRefused, message: "\(uri) is not a view this app can draw.")
        }
        let html: String
        if let text = content["text"]?.stringValue {
            html = text
        } else if let blob = content["blob"]?.stringValue, let data = Data(base64Encoded: blob) {
            html = String(decoding: data, as: UTF8.self)
        } else {
            throw JSONRPCError(code: DaemonAPI.Failure.viewRefused, message: "\(uri) came back empty.")
        }
        let ui = content["_meta"]?["ui"]
        let hash = MCPApprovals.viewHash(uri: uri, mimeType: AppViewResourceType.html, html: html, ui: ui)
        switch mcpApprovalStore.load().viewAnswer(scope: server.scope, server: name, uri: uri, hash: hash) {
        case .show:
            break
        case .hide:
            throw JSONRPCError(code: DaemonAPI.Failure.viewRefused,
                               message: "You chose not to show \(name)'s views here. Ask Again is on its row in the project's MCP servers.")
        case .ask(let isNew):
            DaemonLog.shared.write("view \(uri) of \(name): waiting for Show")
            throw JSONRPCError(code: DaemonAPI.Failure.viewNeedsShow,
                               message: isNew ? "\(name) wants to show a view here." : "\(name)'s view has changed since you said Show.",
                               data: try JSONValue.encoding(DaemonAPI.ViewAsk(server: name, uri: uri, hash: hash, isNew: isNew)))
        }
        let policy = AppViewPolicy(csp: ui?["csp"])
        let who = agents[request.agentID].map { LeaseWords.agentName($0.title) } ?? "a project page"
        DaemonLog.shared.write("view \(uri) of \(name) in \(who): policy \(policy.logLine)")
        return DaemonAPI.ViewResource(uri: uri, html: html, policy: policy, prefersBorder: ui?["prefersBorder"]?.boolValue)
    }

    /// The person's Show or Don't Show, for this version of the view.
    func answerViewShow(_ request: DaemonAPI.ViewShowRequest) throws {
        let project = try viewProject(agentID: request.agentID, claimed: request.project)
        let server = try readyViewServer(request.server, project: project)
        var records = mcpApprovalStore.load()
        records.answerView(scope: server.scope, server: server.name, uri: request.uri, hash: request.hash, show: request.show)
        try mcpApprovalStore.save(records)
        DaemonLog.shared.write("view \(request.uri) of \(server.name): \(request.show ? "shown" : "not shown"), by the person")
    }

    /// The project's MCP row's Ask Again: forget what was said about the server's views.
    func forgetViewAnswers(_ request: DaemonAPI.MCPViewsForgetRequest) throws {
        let scope: String
        switch request.destination {
        case .personal: scope = MCPApprovals.viewScope(nil)
        case .project(let path): scope = MCPApprovals.viewScope(URL(filePath: path))
        }
        var records = mcpApprovalStore.load()
        records.forgetViews(scope: scope, server: request.name)
        try mcpApprovalStore.save(records)
        DaemonLog.shared.write("views of \(request.name): the person asked to be asked again")
    }

    /// A third-party view's `tools/call`: passed through only to the server whose view it
    /// is, and only for a tool its catalog says a view may call.
    func callThirdPartyFromView(_ request: DaemonAPI.ViewCallRequest, server name: String) async throws -> JSONValue {
        let project = try viewProject(agentID: request.agentID, claimed: request.project)
        // The server the view is of, as the daemon wrote it or the project pinned it, not
        // as the request says.
        let own: Bool
        if agents[request.agentID] != nil {
            own = await thirdPartyServer(ofView: request.viewID, agentID: request.agentID) == name
        } else {
            own = readPins(project).pins.contains { $0.view?.server == name }
        }
        guard own else {
            DaemonLog.shared.write("view \(request.viewID) asked for \(name)'s \(request.name), which is not its server's: refused")
            throw JSONRPCError(code: DaemonAPI.Failure.viewRefused,
                               message: "A view may call only its own server's tools, not the \(name) server's.")
        }
        let server = try readyViewServer(name, project: project)
        guard let catalog = await viewCatalog(server), catalog.appTools.contains(request.name) else {
            DaemonLog.shared.write("view \(request.viewID) of \(name) asked for \(request.name), which no view may call")
            throw JSONRPCError(code: DaemonAPI.Failure.viewRefused, message: "A view may not call \(request.name).")
        }
        if request.feed == true, catalog.tool(request.name)?.feedsPins != true {
            DaemonLog.shared.write("pinned view \(request.viewID) asked to be fed by \(name)'s \(request.name), which is not read-only")
            throw JSONRPCError(code: DaemonAPI.Failure.viewRefused,
                               message: "\(request.name) can't feed a pinned view: it is not marked read-only.")
        }
        let tool = request.name
        let arguments = request.arguments ?? [:]
        let result = try await onServer(server) { try await $0.callTool(tool, arguments: arguments) }
        DaemonLog.shared.write("view \(request.viewID) of \(name) called \(tool)")
        return result
    }

    /// A view of the app's own server naming a third-party one, or the other way round:
    /// refused, and logged.
    func refuseAgentsCallFromThirdPartyView(_ request: DaemonAPI.ViewCallRequest) async throws {
        guard agents[request.agentID] != nil,
              let other = await thirdPartyServer(ofView: request.viewID, agentID: request.agentID) else { return }
        DaemonLog.shared.write("view \(request.viewID) of \(other) asked for the \(AppTool.serverName) server's \(request.name): refused")
        throw JSONRPCError(code: DaemonAPI.Failure.viewRefused,
                           message: "A view may call only its own server's tools, not the \(AppTool.serverName) server's.")
    }

    // MARK: Pins (#189, #191)

    /// Why `view` can't be pinned in `project`, or nil: the app's own server's by its
    /// catalog, a person's server's by what was last read of it.
    func viewPinRefusal(_ view: ViewPin, project: URL) -> String? {
        view.server == AppTool.serverName
            ? AppViewCatalog.pinRefusal(view, testView: offersTestView)
            : thirdPartyPinRefusal(view, project: project)
    }

    /// Why a pinned view can't be drawn here, or nil.
    func viewPinMissing(_ view: ViewPin, project: URL) -> String? {
        view.server == AppTool.serverName
            ? AppViewCatalog.missingReason(view, testView: offersTestView)
            : thirdPartyMissingReason(view, project: project)
    }

    /// Why a third-party view can't be pinned, or nil. Read from the catalog as last read:
    /// a view is pinned from where it was drawn, so its server's catalog is here.
    func thirdPartyPinRefusal(_ view: ViewPin, project: URL) -> String? {
        if let problem = PinRules.problem(view) { return problem }
        let server: ViewServer
        switch viewServer(view.server, project: project) {
        case .success(let ready): server = ready
        case .failure(let problem): return problem.words(view.server)
        }
        guard let catalog = cachedViewCatalog(server) else {
            return "the app hasn't read \(view.server)'s views yet. Show one in a chat first."
        }
        guard let tool = catalog.tool(view.tool), tool.resourceURI == view.uri else {
            return "\(view.tool) does not feed \(view.uri) on \(view.server)."
        }
        guard tool.feedsPins else {
            return "\(view.tool) can't feed a pin: only a tool a view may call and that changes nothing "
                + "(readOnlyHint) can, since opening the pin calls it."
        }
        return nil
    }

    /// Why a pinned third-party view can't be drawn on this host, or nil.
    func thirdPartyMissingReason(_ view: ViewPin, project: URL) -> String? {
        switch viewServer(view.server, project: project) {
        case .failure(let problem): return problem.pinReason
        case .success(let server):
            guard let catalog = cachedViewCatalog(server) else { return nil }
            guard let tool = catalog.tool(view.tool), tool.resourceURI == view.uri, tool.feedsPins else {
                return PinMissing.noSuchView
            }
            return nil
        }
    }

    /// For a test: the pool's http through a stand-in, and a shorter idle.
    func setViewClients(_ pool: MCPClientPool) { viewClients = pool }
}
