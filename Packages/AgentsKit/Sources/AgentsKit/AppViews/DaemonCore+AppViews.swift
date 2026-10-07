import AgentsKitCore
import Foundation

/// Views drawn from the `agents` server's `ui://` resources (#187, MCP Apps).
///
/// The daemon is the server, so it is the one place that knows a tool with a view was
/// called, with what, and what it answered. An agent's call writes an `appView` entry as
/// it arrives and again as it is answered, and every client draws the view from that.
/// What a drawn view asks for — its resource, a tool only a view may call, a log line,
/// context for the agent — comes back here through `views/*`, naming the conversation.
extension DaemonCore {
    // MARK: An agent's call

    /// `show_test_view`, or any tool with a view the model may call: on the record as it
    /// arrives, answered, and on the record again with the whole result.
    func viewToolCall(_ request: DaemonAPI.ViewToolCallRequest) async throws -> JSONValue {
        guard let agentID = appTokens[request.token], agents[agentID] != nil else {
            throw JSONRPCError(code: DaemonAPI.Failure.noSuchAgent,
                               message: "That conversation is not open any more, so nothing was shown.")
        }
        guard let tool = AppViewCatalog.tool(named: request.name), tool.forModel,
              let uri = tool.resourceURI else {
            throw JSONRPCError(code: DaemonAPI.Failure.viewRefused, message: "No tool called \(request.name).")
        }
        var call = AppViewCall(tool: tool.name, resourceURI: uri, arguments: request.arguments,
                               pinnable: AppViewCatalog.pinnable(tool: tool.name, uri: uri, testView: offersTestView) ? true : nil)
        runningViews[agentID, default: [:]][call.id] = call
        await record(.appView(call), for: agentID)

        let callID = call.id
        let result = await answer(tool.name, arguments: request.arguments, agentID: agentID) {
            // Still going: a stop takes it off the list, and the wait ends with it.
            await self.runningViews[agentID]?[callID] != nil
        }
        guard runningViews[agentID]?.removeValue(forKey: call.id) != nil else {
            return ["content": [["type": "text", "text": "The turn was stopped before the view was answered."]],
                    "isError": true]
        }
        if runningViews[agentID]?.isEmpty == true { runningViews.removeValue(forKey: agentID) }
        call.result = result
        call.state = .done
        await record(.appView(call), for: agentID)
        return result
    }

    /// Offer the test view to pins, as `AGENTS_TEST_VIEWS=1` does: for tests.
    func offerTestView(_ on: Bool) { offersTestView = on }

    /// Every view of `agentID` still waiting for its answer, said to be cancelled.
    func cancelViews(for agentID: UUID, reason: String) async {
        guard let waiting = runningViews.removeValue(forKey: agentID) else { return }
        for var call in waiting.values.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            call.state = .cancelled
            call.reason = reason
            await record(.appView(call), for: agentID)
        }
    }

    /// What a tool answers. `stillWanted` is asked while a call waits on purpose.
    private func answer(_ name: String, arguments: JSONValue?, agentID: UUID,
                        stillWanted: @Sendable () async -> Bool = { true }) async -> JSONValue {
        switch name {
        case AppService.readDashboardToolName:
            guard let token = appTokens.first(where: { $0.value == agentID })?.key,
                  let agent = agents[agentID] else {
                return ["content": [], "isError": true]
            }
            let snapshot = dashboardSnapshot(Project.standardize(agent.cwd), withUpdate: true)
            let text = (try? readDashboard(DaemonAPI.DashboardTokenRequest(token: token))) ?? "Dashboard"
            return ["content": [["type": "text", "text": .string(text)]],
                    "structuredContent": (try? JSONValue.encoding(snapshot)) ?? .object([:])]
        case "dashboard_action":
            return ["content": [["type": "text", "text": .string("Dashboard action is unavailable.")]], "isError": true]
        case AppViewCatalog.showTestView:
            let seconds = min(30, max(0, arguments?["seconds"]?.intValue ?? 0))
            var waited = 0.0
            while waited < Double(seconds), await stillWanted() {
                try? await Task.sleep(for: .milliseconds(250))
                waited += 0.25
            }
            let note = arguments?["note"]?.stringValue ?? ""
            return [
                "content": [["type": "text", "text": "The test view is shown in the conversation."]],
                "structuredContent": ["note": .string(note),
                                      "answeredAt": .string(ISO8601DateFormatter().string(from: now()))],
            ]
        case AppViewCatalog.testViewCount:
            let by = max(-1000, min(1000, arguments?["by"]?.intValue ?? 1))
            let count = viewCounts[agentID, default: 0] + by
            viewCounts[agentID] = count
            return ["content": [["type": "text", "text": .string("Count is \(count).")]],
                    "structuredContent": ["count": .int(count)]]
        default:
            return ["content": [["type": "text", "text": .string("No tool called \(name).")]], "isError": true]
        }
    }

    // MARK: What a drawn view asks for

    /// `resources/read`, for a view drawn in `agentID`'s conversation, with the policy it
    /// is to be drawn under. The policy goes in the log, as the spec asks.
    ///
    /// A project page names no conversation (#188): the catalog still answers, and the log
    /// says it was a project page.
    func readView(_ request: DaemonAPI.ViewReadRequest) async throws -> DaemonAPI.ViewResource {
        if let server = request.server, server != AppTool.serverName {
            return try await readThirdPartyView(request, server: server)
        }
        guard let resource = AppViewCatalog.resource(request.uri) else {
            throw JSONRPCError(code: DaemonAPI.Failure.viewRefused, message: "No view at \(request.uri).")
        }
        let policy = AppViewPolicy(csp: resource.meta?["ui"]?["csp"])
        let who = agents[request.agentID].map { LeaseWords.agentName($0.title) } ?? "a project page"
        DaemonLog.shared.write("view \(resource.uri) in \(who): policy \(policy.logLine)")
        return DaemonAPI.ViewResource(uri: resource.uri, html: resource.html, policy: policy,
                                      prefersBorder: resource.meta?["ui"]?["prefersBorder"]?.boolValue)
    }

    /// A view's `tools/call`: only a tool of this server that a view may call.
    func callFromView(_ request: DaemonAPI.ViewCallRequest) async throws -> JSONValue {
        if let server = request.server, server != AppTool.serverName {
            return try await callThirdPartyFromView(request, server: server)
        }
        try await refuseAgentsCallFromThirdPartyView(request)
        let project: URL
        if let agent = agents[request.agentID] {
            project = Project.standardize(agent.projectFolder)
            if let claimed = request.project, Project.standardize(claimed) != project {
                throw JSONRPCError(code: DaemonAPI.Failure.viewRefused, message: "That view is outside its project.")
            }
        } else if let claimed = request.project, isProject(Project.standardize(claimed)) {
            project = Project.standardize(claimed)
        } else {
            throw JSONRPCError(code: DaemonAPI.Failure.noSuchAgent, message: "That view has no project.")
        }
        // The exact name: a view names the server's own tool, never a runtime's spelling.
        guard let tool = AppViewCatalog.tools().first(where: { $0.name == request.name }), tool.forApp else {
            DaemonLog.shared.write("view \(request.viewID) asked for \(request.name), which no view may call")
            throw JSONRPCError(code: DaemonAPI.Failure.viewRefused,
                               message: "A view may not call \(request.name).")
        }
        // A pin's feeding call (#189): opening a pin must never change anything.
        if request.feed == true, !tool.feedsPins {
            DaemonLog.shared.write("pinned view \(request.viewID) asked to be fed by \(request.name), which is not read-only")
            throw JSONRPCError(code: DaemonAPI.Failure.viewRefused,
                               message: "\(request.name) can't feed a pinned view: it is not marked read-only.")
        }
        if tool.name == "dashboard_action" {
            return try await dashboardViewAction(request.arguments, project: project)
        }
        return await answer(tool.name, arguments: request.arguments, agentID: request.agentID)
    }

    /// The app-only Dashboard tool acts on the host's project, never a folder supplied by
    /// the HTML. Every write uses the same person's operations as the native page.
    private func dashboardViewAction(_ arguments: JSONValue?, project: URL) async throws -> JSONValue {
        guard let action = arguments?["action"]?.stringValue else {
            throw dashboardRefusal("Choose a Dashboard action.")
        }
        let id = arguments?["id"]?.stringValue ?? ""
        let tile = dashboardSnapshot(project, withUpdate: false).tiles.first { $0.id == id }
        func result(_ words: String, extra: JSONValue? = nil) -> JSONValue {
            if let extra {
                return ["content": [["type": "text", "text": .string(words)]], "structuredContent": extra]
            }
            return ["content": [["type": "text", "text": .string(words)]]]
        }
        switch action {
        case "update":
            _ = try await updateDashboard(.init(folder: project))
            return result("Dashboard update started.")
        case "hide", "show":
            try setTileHidden(.init(folder: project, id: id), hidden: action == "hide")
            return result("Tile \(action == "hide" ? "hidden" : "shown").")
        case "remove":
            try removeTileByPerson(.init(folder: project, id: id), from: nil)
            return result("Tile removed.")
        case "move":
            guard tile != nil else { throw dashboardRefusal("Move needs a tile.") }
            let snapshot = dashboardSnapshot(project, withUpdate: false)
            let order: DashboardOrder
            if let section = arguments?["section"]?.stringValue {
                let title: String? = section.isEmpty ? nil : section
                guard DashboardModel.sections(snapshot, includeHidden: true).contains(where: { $0.title == title }) else {
                    throw dashboardRefusal("This Dashboard has no such section.")
                }
                order = DashboardModel.arrangement(snapshot).moving([id], to: title)
            } else if let step = arguments?["step"]?.intValue, abs(step) == 1,
                      let stepped = DashboardModel.stepping(id, by: step, in: snapshot, includeHidden: true) {
                order = stepped
            } else {
                throw dashboardRefusal("The tile is already at the edge of its section.")
            }
            try arrangeDashboard(.init(folder: project, order: order))
            return result("Tile moved.")
        case "move_section":
            let snapshot = dashboardSnapshot(project, withUpdate: false)
            let sections = DashboardModel.arrangement(snapshot).sections
            let title = arguments?["section"]?.stringValue
            let name = title.flatMap { $0.isEmpty ? nil : $0 }
            guard let at = sections.firstIndex(where: { $0.title == name }),
                  let step = arguments?["step"]?.intValue, abs(step) == 1,
                  sections.indices.contains(at + step) else {
                throw dashboardRefusal("The section is already at the edge of the Dashboard.")
            }
            let before: String?? = at + step + (step > 0 ? 1 : 0) < sections.count
                ? .some(sections[at + step + (step > 0 ? 1 : 0)].title) : nil
            let order = DashboardModel.arrangement(snapshot).movingSection(name, before: before)
            try arrangeDashboard(.init(folder: project, order: order))
            return result("Section moved.")
        case "open_keeper":
            guard let tile, !tile.keeper.id.isEmpty else { throw dashboardRefusal("This tile has no keeper to open.") }
            return result("Opening keeper.", extra: ["open": ["kind": .string(tile.keeper.kind.rawValue),
                                                              "id": .string(tile.keeper.id)]])
        case "open_page":
            guard let tile, let file = tile.tile?.page?.file ?? tile.tile?.link?.file else {
                throw dashboardRefusal("This tile has no page to open.")
            }
            _ = try readPage(.init(folder: project, path: file))
            return result("Opening page.", extra: ["open": ["kind": "page", "id": .string(file)]])
        case "open_link":
            guard let tile, let kind = arguments?["kind"]?.stringValue else {
                throw dashboardRefusal("This tile has no destination.")
            }
            let destination = kind == "agent" ? tile.tile?.link?.session :
                kind == "workflow" ? tile.tile?.link?.workflow : nil
            guard let destination, !destination.isEmpty else {
                throw dashboardRefusal("This tile has no \(kind) destination.")
            }
            return result("Opening \(kind).", extra: ["open": ["kind": .string(kind), "id": .string(destination)]])
        case "read_page":
            guard let tile, let file = tile.tile?.page?.file else {
                throw dashboardRefusal("This tile has no page to read.")
            }
            switch try readPage(.init(folder: project, path: file)) {
            case .text(let text, _, _, _):
                return result("Page read.", extra: ["text": .string(text)])
            default: throw dashboardRefusal("This page cannot be shown as text.")
            }
        default:
            throw dashboardRefusal("Unknown Dashboard action \(action).")
        }
    }

    /// A view's `notifications/message`.
    func logFromView(_ request: DaemonAPI.ViewLogRequest) {
        let title = agents[request.agentID].map { LeaseWords.agentName($0.title) } ?? request.agentID.uuidString
        let text: String
        if let words = request.data?.stringValue {
            text = words
        } else if let data = request.data, let encoded = try? JSONEncoder().encode(data) {
            text = String(decoding: encoded, as: UTF8.self)
        } else {
            text = ""
        }
        DaemonLog.shared.write("view \(request.viewID) in \(title) [\(request.level ?? "info")]: \(text.prefix(2000))")
    }

    /// A view's `ui/update-model-context`: the last one of each view is told to the agent
    /// with the person's next message, before their words (`takeViewContext`).
    func keepViewContext(_ request: DaemonAPI.ViewContextRequest) throws {
        guard agents[request.agentID] != nil else {
            // A project's page (the Dashboard, a pin) has no agent to tell (#189).
            DaemonLog.shared.write("view \(request.viewID) on a project page asked to update the model's context: refused")
            throw JSONRPCError(code: DaemonAPI.Failure.viewRefused,
                               message: "A view on a project's page has no agent to tell.")
        }
        let title = request.uri.flatMap { AppViewCatalog.resource($0)?.title } ?? "a view"
        let preface = AppViewBridge.contextPreface(viewTitle: title, content: request.content,
                                                   structuredContent: request.structuredContent)
        if let preface {
            viewContexts[request.agentID, default: [:]][request.viewID] = preface
        } else {
            viewContexts[request.agentID]?.removeValue(forKey: request.viewID)
        }
    }

    /// Every view's context for `agentID`, taken: it goes with this message and no other.
    func takeViewContext(_ agentID: UUID) -> String? {
        guard let kept = viewContexts.removeValue(forKey: agentID), !kept.isEmpty else { return nil }
        return kept.keys.sorted { $0.uuidString < $1.uuidString }.compactMap { kept[$0] }.joined(separator: "\n\n")
    }
}
