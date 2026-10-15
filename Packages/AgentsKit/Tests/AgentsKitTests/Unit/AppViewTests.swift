import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// Views drawn from `ui://` resources (#187, MCP Apps): the policy they are held to, the
/// host's half of their conversation, how the chat keeps them, and what the `agents`
/// server offers.
@Suite("Views (MCP Apps)", .timeLimit(.minutes(1)))
struct AppViewTests {
    // MARK: The policy

    @Test func nothingDeclaredIsTheSpecsStrictDefault() {
        let header = AppViewPolicy(csp: nil).header
        #expect(header.contains("default-src 'none'"))
        #expect(header.contains("connect-src 'none'"))
        #expect(header.contains("frame-src 'none'"))
        #expect(header.contains("object-src 'none'"))
        #expect(header.contains("base-uri 'self'"))
        #expect(header.contains("script-src 'self' 'unsafe-inline';"))
        #expect(header.contains("img-src 'self' data: blob:;"))
        #expect(!header.contains("http"))
    }

    @Test func declaredOriginsAreAllowedWhereTheyWereDeclared() {
        let policy = AppViewPolicy(csp: ["connectDomains": ["https://api.example.com", "wss://live.example.com:8443"],
                                         "resourceDomains": ["https://*.cdn.example.net"],
                                         "frameDomains": ["https://www.youtube.com"]])
        #expect(policy.refused.isEmpty)
        let header = policy.header
        #expect(header.contains("connect-src https://api.example.com wss://live.example.com:8443"))
        #expect(header.contains("script-src 'self' 'unsafe-inline' https://*.cdn.example.net"))
        #expect(header.contains("frame-src https://www.youtube.com"))
        #expect(header.contains("object-src 'none'"))
    }

    /// Never loosened: nothing a server writes may widen the policy past an origin.
    @Test func anythingButAPlainOriginIsRefused() {
        let tries: [JSONValue] = ["*", "https:", "'unsafe-eval'", "https://a.com; script-src *", "https://*",
                                  "javascript:alert(1)", "data:", "https://a b.com", "https://a.com:99999",
                                  "https://-bad.com", "ftp://a.com", "https://a.com/path"]
        let policy = AppViewPolicy(csp: ["connectDomains": .array(tries), "resourceDomains": .array(tries)])
        #expect(policy.connectDomains.isEmpty)
        #expect(policy.resourceDomains.isEmpty)
        #expect(policy.header == AppViewPolicy.strict.header)
        #expect(policy.refused.count == tries.count * 2)
        #expect(policy.logLine.hasPrefix("strict (no network); refused"))
    }

    @Test func theContentRulesBlockAllButTheDeclaredOrigins() throws {
        let policy = AppViewPolicy(csp: ["connectDomains": ["https://api.example.com"],
                                         "resourceDomains": ["https://*.cdn.example.net"]])
        let rules = try JSONValue.parse(Data(policy.contentRules.utf8)).arrayValue ?? []
        #expect(rules.first?["action"]?["type"]?.stringValue == "block")
        let allowed = rules.dropFirst().compactMap { $0["trigger"]?["url-filter"]?.stringValue }
        #expect(allowed.contains("^https://api\\.example\\.com[:/?#]"))
        #expect(allowed.contains("^https://[a-z0-9.-]*\\.cdn\\.example\\.net[:/?#]"))
        #expect(allowed.contains("^agents-view:"))
        // No alternation: WebKit's filters have none.
        #expect(!allowed.contains { $0.contains("|") })
        #expect(AppViewPolicy.strict.rulesIdentifier != policy.rulesIdentifier)
    }

    // MARK: The shell

    @Test func theShellPutsThePolicyOnTheFrameAndTheViewInASandbox() {
        let page = AppViewShell.page(html: "<html><head><title>x</title></head><body>\"hi\" & <b>bye</b></body></html>",
                                     policy: .strict)
        #expect(page.contains("sandbox=\"allow-scripts\""))
        #expect(!page.contains("allow-same-origin"))
        #expect(page.contains("http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'"))
        // The view's own head has the policy first, escaped into the attribute.
        #expect(page.contains("srcdoc=\"&lt;html&gt;&lt;head&gt;&lt;meta http-equiv=&quot;Content-Security-Policy&quot;"))
        #expect(page.contains("&quot;hi&quot; &amp; &lt;b&gt;"))
    }

    @Test func aViewWithNoHeadStillGetsThePolicyFirst() {
        #expect(AppViewShell.withPolicy("<p>bare</p>", .strict).hasPrefix("<head><meta http-equiv"))
        #expect(AppViewShell.withPolicy("<html lang=en><p>x</p>", .strict)
            .hasPrefix("<html lang=en><head><meta http-equiv"))
    }

    // MARK: The bridge

    @Test func theBridgeReadsWhatAViewAsks() {
        func ask(_ method: String, _ params: JSONValue = [:], id: JSONValue? = 1) -> AppViewBridge.Ask {
            var message: [String: JSONValue] = ["jsonrpc": "2.0", "method": .string(method), "params": params]
            if let id { message["id"] = id }
            return AppViewBridge.read(.object(message))
        }
        #expect(ask("ui/initialize") == .initialize(id: 1))
        #expect(ask("ui/notifications/initialized", id: nil) == .initialized)
        #expect(ask("tools/call", ["name": "test_view_count", "arguments": ["by": 1]])
            == .callTool(id: 1, name: "test_view_count", arguments: ["by": 1]))
        #expect(ask("resources/read", ["uri": "ui://agents/test-view"]) == .readResource(id: 1, uri: "ui://agents/test-view"))
        #expect(ask("ui/open-link", ["url": "https://example.com/"])
            == .openLink(id: 1, url: URL(string: "https://example.com/")!))
        if case .malformed = ask("ui/open-link", ["url": "file:///etc/passwd"]) {} else { Issue.record("a file link") }
        if case .malformed = ask("ui/open-link", ["url": "javascript:alert(1)"]) {} else { Issue.record("a script link") }
        #expect(ask("ui/message", ["role": "user", "content": ["type": "text", "text": " Hi "]]) == .message(id: 1, text: "Hi"))
        #expect(ask("ui/message", ["role": "user", "content": [["type": "text", "text": "a"], ["type": "text", "text": "b"]]])
            == .message(id: 1, text: "a\nb"))
        #expect(ask("ui/request-display-mode", ["mode": "fullscreen"]) == .displayMode(id: 1, mode: "fullscreen"))
        #expect(ask("ui/notifications/size-changed", ["width": 300, "height": 120.5], id: nil)
            == .sizeChanged(width: 300, height: 120.5))
        #expect(ask("notifications/message", ["level": "info", "data": "x"], id: nil) == .log(level: "info", data: "x"))
        #expect(ask("sampling/createMessage") == .unknown(id: 1, method: "sampling/createMessage"))
        #expect(AppViewBridge.read(["jsonrpc": "2.0", "id": "teardown-1", "result": [:]]) == .answered(id: "teardown-1"))
        #expect(AppViewBridge.read(["method": "ui/initialize", "id": 1]) == .ignored)
    }

    @Test func aViewAsksForTheNewAgentFormFilledIn() {
        func ask(_ params: JSONValue) -> AppViewBridge.Ask {
            AppViewBridge.read(["jsonrpc": "2.0", "id": 7, "method": "agents/start-agent", "params": params])
        }
        #expect(ask(["prompt": " Work on #834 ", "labels": ["#834", " #834 "], "worktree": "834 start an agent"])
            == .startAgent(id: 7, start: AppViewStart(prompt: "Work on #834", labels: ["#834"], worktree: "834 start an agent")))
        #expect(ask(["prompt": "Go", "worktree": ""]) == .startAgent(id: 7, start: AppViewStart(prompt: "Go")))
        if case .malformed = ask([:]) {} else { Issue.record("no prompt") }
        if case .malformed = ask(["prompt": .string(String(repeating: "x", count: AppViewStart.promptLimit + 1))]) {} else {
            Issue.record("a prompt too long")
        }
        if case .malformed = ask(["prompt": "Go", "labels": [1]]) {} else { Issue.record("a label that is not text") }
        if case .malformed = ask(["prompt": "Go", "labels": [.string(String(repeating: "x", count: 25))]]) {} else {
            Issue.record("a label too long for a session")
        }
        if case .malformed = ask(["prompt": "Go", "labels": .array((0...5).map { .string("l\($0)") })]) {} else {
            Issue.record("too many labels")
        }
    }

    @Test func aViewAsksToMessageTheAgentOnABranch() {
        func ask(_ params: JSONValue) -> AppViewBridge.Ask {
            AppViewBridge.read(["jsonrpc": "2.0", "id": 8, "method": "agents/message-agent", "params": params])
        }
        #expect(ask(["branch": " agents/fix-837 ", "text": " Fix the review \n"])
            == .messageAgent(id: 8, message: AppViewAgentMessage(branch: "agents/fix-837", text: "Fix the review")))
        if case .malformed = ask(["text": "Fix"]) {} else { Issue.record("no branch") }
        if case .malformed = ask(["branch": "b", "text": "  "]) {} else { Issue.record("no text") }
        if case .malformed = ask(["branch": "b", "text": .string(String(repeating: "x", count: AppViewAgentMessage.textLimit + 1))]) {} else {
            Issue.record("text too long")
        }
        if case .malformed = ask(["branch": .string(String(repeating: "b", count: 256)), "text": "Fix"]) {} else {
            Issue.record("a branch too long")
        }
    }

    /// The session on the branch, in the view's project, on its host: the latest active one
    /// not archived.
    @Test func theMessageGoesToTheLatestSessionOnTheBranch() {
        let project = URL(fileURLWithPath: "/tmp/repo")
        func agent(_ title: String?, branch: String?, host: HostID = .mac, project: URL = project,
                   active: TimeInterval, archived: Bool = false) -> Agent {
            var a = Agent(id: UUID(), runtimeID: "claude", cwd: project.appendingPathComponent(".agents/worktrees/w"),
                          title: title, state: .finished)
            a.host = host
            a.lastActivityAt = Date(timeIntervalSince1970: active)
            a.worktree = AgentWorktree(name: "fix-837", root: a.cwd, branch: branch, project: project, base: "main", madeByApp: true)
            if archived { a.archivedAt = Date() }
            return a
        }
        let older = agent("Older", branch: "agents/fix-837", active: 10)
        let newer = agent("Newer", branch: "agents/fix-837", active: 20)
        let others: [Agent] = [
            agent("Archived", branch: "agents/fix-837", active: 30, archived: true),
            agent("Other host", branch: "agents/fix-837", host: HostID(rawValue: "linux"), active: 40),
            agent("Other project", branch: "agents/fix-837", project: URL(fileURLWithPath: "/tmp/other"), active: 50),
            agent("Other branch", branch: "agents/fix-838", active: 60),
        ]
        let message = AppViewAgentMessage(branch: "agents/fix-837", text: "Fix")
        #expect(message.recipient(among: [older, newer] + others, host: .mac, project: URL(fileURLWithPath: "/tmp/repo/"))?.id == newer.id)
        #expect(message.recipient(among: others.filter { $0.title != "Other host" }, host: .mac, project: project) == nil)
        #expect(AppViewAgentMessage.name(of: newer) == "Newer")
        #expect(AppViewAgentMessage.name(of: agent(nil, branch: "b", active: 0)) == "fix-837")
    }

    @Test func aStartMayNameABranchForItsWorktree() {
        let read = AppViewStart.read(["prompt": "Fix PR #9", "worktree": "w", "branch": " agents/fix-9 "])
        let start = try? read.get()
        #expect(start?.branch == "agents/fix-9")
        #expect(start?.worktreeChoice == .branch("agents/fix-9"))
        #expect(AppViewStart(prompt: "Go", worktree: "w").worktreeChoice == .named("w"))
        #expect(AppViewStart(prompt: "Go").worktreeChoice == nil)
    }

    @Test func theInitializeAnswerCarriesTheHostContext() {
        let context = AppViewContext(theme: "dark", platform: .desktop, width: 640, maxHeight: 640,
                                     locale: "en-GB", timeZone: "Europe/London", touch: false, hover: true)
        let result = AppViewBridge.initializeResult(context, policy: .strict)
        #expect(result["protocolVersion"]?.stringValue == "2026-01-26")
        let host = result["hostContext"]
        #expect(host?["theme"]?.stringValue == "dark")
        #expect(host?["platform"]?.stringValue == "desktop")
        #expect(host?["locale"]?.stringValue == "en-GB")
        #expect(host?["timeZone"]?.stringValue == "Europe/London")
        #expect(host?["containerDimensions"] == ["width": 640.0, "maxHeight": 640.0])
        #expect(host?["safeAreaInsets"]?["top"] != nil)
        #expect(host?["availableDisplayModes"] == ["inline", "fullscreen"])
        let background = host?["styles"]?["variables"]?["--color-background-primary"]?.stringValue
        #expect(background == "light-dark(#f7f8f9, #1c1d20)")
        #expect(result["hostCapabilities"]?["serverTools"] != nil)
    }

    @Test func theToolInfoIsAWholeToolWithAnInputSchema() {
        // The ext-apps SDK checks hostContext.toolInfo.tool against MCP's Tool, which needs an
        // inputSchema; without one its app never connects (#191's walk).
        let context = AppViewContext(theme: "light", platform: .desktop, width: 600, maxHeight: 640, touch: false,
                                     hover: true, toolInfo: AppViewBridge.toolInfo("get-time"))
        let tool = AppViewBridge.initializeResult(context, policy: .strict)["hostContext"]?["toolInfo"]?["tool"]
        #expect(tool?["name"]?.stringValue == "get-time")
        #expect(tool?["inputSchema"]?["type"]?.stringValue == "object")
    }

    @Test func onlyWhatChangedIsSaidAgain() {
        let before = AppViewContext(theme: "light", platform: .mobile, width: 390, maxHeight: 640, touch: true, hover: false)
        var after = before
        after.theme = "dark"
        #expect(after.changes(since: before) == ["theme": "dark"])
        #expect(before.changes(since: before) == nil)
        var full = before
        full.displayMode = "fullscreen"
        full.height = 700
        full.maxHeight = nil
        #expect(full.changes(since: before)?["containerDimensions"] == ["width": 390.0, "height": 700.0])
    }

    /// The input after the view is initialized and never before; then the result or the
    /// cancellation, once.
    @Test func theFeedSaysEachThingOnceAndInOrder() {
        var call = AppViewCall(tool: "show_test_view", resourceURI: "ui://agents/test-view", arguments: ["note": "x"])
        var feed = AppViewFeed()
        #expect(feed.due(call).isEmpty)
        let first = feed.viewInitialized(call)
        #expect(first.map { $0["method"]?.stringValue } == ["ui/notifications/tool-input"])
        #expect(first.first?["params"]?["arguments"] == ["note": "x"])
        #expect(feed.due(call).isEmpty)
        call.state = .done
        call.result = ["content": [], "structuredContent": ["a": 1]]
        let done = feed.due(call)
        #expect(done.map { $0["method"]?.stringValue } == ["ui/notifications/tool-result"])
        #expect(done.first?["params"]?["structuredContent"] == ["a": 1])
        #expect(feed.due(call).isEmpty)
        // A view left open says a later result again (#188). A cancellation does not.
        call.result = ["content": [], "structuredContent": ["a": 2]]
        let again = feed.due(call)
        #expect(again.map { $0["method"]?.stringValue } == ["ui/notifications/tool-result"])
        #expect(again.first?["params"]?["structuredContent"] == ["a": 2])
        #expect(feed.due(call).isEmpty)

        var cancelled = AppViewCall(tool: "t", resourceURI: "ui://a", state: .cancelled, reason: "Stopped.")
        var late = AppViewFeed()
        let both = late.viewInitialized(cancelled)
        #expect(both.map { $0["method"]?.stringValue }
            == ["ui/notifications/tool-input", "ui/notifications/tool-cancelled"])
        cancelled.state = .done
        #expect(late.due(cancelled).isEmpty)
    }

    @Test func aViewsContextIsToldInWordsAndCut() {
        #expect(AppViewBridge.contextPreface(viewTitle: "Test view", content: nil, structuredContent: nil) == nil)
        #expect(AppViewBridge.contextPreface(viewTitle: "Test view", content: [["type": "text", "text": "  "]],
                                             structuredContent: nil) == nil)
        let words = AppViewBridge.contextPreface(viewTitle: "Test view", content: [["type": "text", "text": "Count is 3."]],
                                                 structuredContent: ["count": 3])
        #expect(words?.contains("“Test view”") == true)
        #expect(words?.contains("Count is 3.\n{\"count\":3}") == true)
        let long = AppViewBridge.contextPreface(viewTitle: "v", content: [["type": "text", "text": .string(String(repeating: "x", count: 20000))]],
                                                structuredContent: nil)
        #expect((long?.count ?? 0) < AppViewBridge.contextLimit + 200)
    }

    // MARK: Loading (#978)

    /// A `views/read` that never answers — a link that dropped while it was in flight — ends
    /// failed, in words, so the view says why and offers Try Again rather than a blank box.
    @Test func aReadThatNeverAnswersEndsFailed() async {
        let outcome = await AppViewLoad.read(DaemonAPI.ViewReadRequest(agentID: UUID(), uri: "ui://agents/test"),
                                             within: .milliseconds(50)) { _, _ in
            try await Task.sleep(for: .seconds(30))
            return [:]
        }
        guard case .failed(let words) = outcome else { Issue.record("not failed: \(outcome)"); return }
        #expect(words.contains("could not be read"))
        #expect(words.contains("no answer"))
    }

    @Test func aReadThatAnswersIsTheResource() async throws {
        let resource = DaemonAPI.ViewResource(uri: "ui://agents/test", html: "<p>hi</p>", policy: .strict)
        let value = try JSONValue.encoding(resource)
        let outcome = await AppViewLoad.read(DaemonAPI.ViewReadRequest(agentID: UUID(), uri: resource.uri)) { method, _ in
            #expect(method == DaemonAPI.Method.viewsRead)
            return value
        }
        #expect(outcome == .resource(resource))
    }

    @Test func aViewWaitingOnShowAsks() async throws {
        let ask = DaemonAPI.ViewAsk(server: "mine", uri: "ui://mine/v", hash: "h", isNew: true)
        let data = try JSONValue.encoding(ask)
        let outcome = await AppViewLoad.read(DaemonAPI.ViewReadRequest(agentID: UUID(), uri: ask.uri)) { _, _ in
            throw JSONRPCError(code: DaemonAPI.Failure.viewNeedsShow, message: "Show?", data: data)
        }
        #expect(outcome == .asking(ask))
    }

    // MARK: The record and the chat

    @Test func aViewIsDrawnOnceWhereItsCallBeganWithItsLatestState() throws {
        var call = AppViewCall(tool: "show_test_view", resourceURI: "ui://agents/test-view", arguments: ["note": "x"])
        let started = TranscriptEntry(kind: .appView(call))
        call.state = .done
        call.result = ["content": [["type": "text", "text": "Shown."]]]
        let answered = TranscriptEntry(kind: .appView(call))
        let items = TranscriptEntry.display([
            TranscriptEntry(kind: .agentMessage(messageID: "m", text: "Here it is.")),
            started,
            TranscriptEntry(kind: .agentMessage(messageID: "n", text: "Done.")),
            answered,
        ])
        let views = items.compactMap { item -> AppViewCall? in
            if case .entry(let entry) = item, case .appView(let call) = entry.kind { return call }
            return nil
        }
        #expect(views.count == 1)
        #expect(views.first?.state == .done)
        #expect(views.first?.resultText == "Shown.")
        // Drawn where it began: between the two messages.
        try #require(items.count == 3)
        if case .entry(let entry) = items[1], case .appView = entry.kind {} else { Issue.record("not where it began") }
        // And drawn at every level, as an outcome is.
        #expect(items[1].isOutcome)

        // Kept as written, and read back.
        let data = try StoreCoding.encoder.encode(answered)
        let back = try StoreCoding.decoder.decode(TranscriptEntry.self, from: data)
        #expect(back.kind == answered.kind)
        #expect(String(decoding: data, as: UTF8.self).contains("\"resourceUri\""))
    }

    // MARK: The server

    private func service(testView: Bool,
                         viewTool: @escaping AppService.ViewToolSink = { _, _ in .failure("not expected") }) -> AppService {
        AppService(transport: nil, viewTool: viewTool, offersTestView: testView)
    }

    @Test func withoutTheSwitchNothingOfTheTestViewIsOffered() async throws {
        let server = service(testView: false)
        let tools = try await server.handle(method: "tools/list", params: [:]).get()["tools"]?.arrayValue ?? []
        #expect(!tools.contains { $0["name"]?.stringValue?.contains("test_view") == true })
        let resources = try await server.handle(method: "resources/list", params: [:]).get()["resources"]?.arrayValue
        #expect(resources?.isEmpty == true)
        // No such tool: the JSON-RPC error, as for any name the server does not have.
        if case .success = await server.handle(method: "tools/call", params: ["name": "show_test_view"]) {
            Issue.record("the test view's tool answered without the switch")
        }
    }

    @Test func theModelIsOfferedTheViewsToolAndNeverTheOneOnlyAViewMayCall() async throws {
        let server = service(testView: true) { name, arguments in
            .success(["content": [["type": "text", "text": .string("ran \(name)")]],
                      "structuredContent": ["note": arguments?["note"] ?? .null]])
        }
        let tools = try await server.handle(method: "tools/list", params: [:]).get()["tools"]?.arrayValue ?? []
        let shown = tools.first { $0["name"]?.stringValue == AppViewCatalog.showTestView }
        #expect(shown?["_meta"]?["ui"]?["resourceUri"]?.stringValue == AppViewCatalog.testViewURI)
        #expect(!tools.contains { $0["name"]?.stringValue == AppViewCatalog.testViewCount })

        let result = try await server.handle(method: "tools/call",
                                             params: ["name": "mcp__agents__show_test_view",
                                                      "arguments": ["note": "hi"]]).get()
        #expect(result["structuredContent"]?["note"]?.stringValue == "hi")

        let refused = try await server.handle(method: "tools/call", params: ["name": "test_view_count"]).get()
        #expect(refused["isError"]?.boolValue == true)
    }

    @Test func theViewsResourceIsReadAsTheSpecSays() async throws {
        let server = service(testView: true)
        let initialize = try await server.handle(method: "initialize", params: [:]).get()
        #expect(initialize["capabilities"]?["resources"] != nil)
        let listed = try await server.handle(method: "resources/list", params: [:]).get()["resources"]?.arrayValue ?? []
        #expect(listed.first?["mimeType"]?.stringValue == "text/html;profile=mcp-app")
        let read = try await server.handle(method: "resources/read", params: ["uri": .string(AppViewCatalog.testViewURI)]).get()
        let contents = read["contents"]?.arrayValue?.first
        #expect(contents?["uri"]?.stringValue == AppViewCatalog.testViewURI)
        #expect(contents?["mimeType"]?.stringValue == "text/html;profile=mcp-app")
        #expect(contents?["text"]?.stringValue?.contains("ui/initialize") == true)
        #expect(contents?["_meta"]?["ui"]?["csp"] == nil)
        let missing = await server.handle(method: "resources/read", params: ["uri": "ui://agents/nope"])
        if case .success = missing { Issue.record("an unknown resource was read") }
    }
}
