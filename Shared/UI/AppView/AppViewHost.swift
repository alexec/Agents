import AgentsKitCore
import SwiftUI
import WebKit

/// What a view drawn in the chat needs from the app it is drawn in (#187). The Mac's and the
/// phone's are the same calls to the host the conversation is on; only who answers differs.
struct AppViewActions {
    /// The conversation the views are in.
    var agentID: UUID
    /// One of `views/*`, to the host the conversation is on.
    var call: @MainActor (String, JSONValue) async throws -> JSONValue
    /// A `ui/message` the person said yes to, sent as their prompt.
    var send: @MainActor (String) async -> Bool
    /// A `ui/open-link`, in the default browser.
    var openLink: @MainActor (URL) -> Void
}

/// The views open in one chat, kept by call so a view keeps what it is showing while it is
/// scrolled off and back, and goes full screen as the same view rather than a new one.
/// Each is torn down — told first, as MCP Apps asks — when the chat closes, and the oldest
/// when more than `limit` are open.
@MainActor @Observable
final class AppViewStore {
    /// The view drawn in the chat's place, if one is.
    var fullscreen: UUID?
    @ObservationIgnored private var hosts: [UUID: AppViewHost] = [:]
    @ObservationIgnored private var order: [UUID] = []
    static let limit = 8

    /// The host for this call, made the first time it is drawn.
    func host(for call: AppViewCall, actions: AppViewActions) -> AppViewHost {
        if let host = hosts[call.id] {
            // Never another chat's: a row still drawn as the chat changes keeps its own.
            if actions.agentID == host.actions.agentID { host.actions = actions }
            host.update(call)
            order.removeAll { $0 == call.id }
            order.append(call.id)
            return host
        }
        let host = AppViewHost(call: call, actions: actions, store: self)
        hosts[call.id] = host
        order.append(call.id)
        while order.count > Self.limit, let oldest = order.first {
            order.removeFirst()
            if let gone = hosts.removeValue(forKey: oldest) {
                Task { await gone.tearDown(reason: "Too many views were open in this conversation.") }
            }
        }
        return host
    }

    func existing(_ id: UUID) -> AppViewHost? { hosts[id] }

    /// Every view, told and then taken down: the chat is closing or changing.
    func tearDownAll(reason: String = "The conversation was closed.") {
        let all = hosts.values
        hosts = [:]
        order = []
        fullscreen = nil
        for host in all { Task { await host.tearDown(reason: reason) } }
    }
}

/// One view: its web view, the conversation with it, and what the chat draws around it.
@MainActor @Observable
final class AppViewHost {
    enum Phase: Equatable { case loading, ready, failed(String), gone }

    private(set) var call: AppViewCall
    private(set) var phase: Phase = .loading
    /// The height the view asked for, inline.
    private(set) var height: CGFloat = 96
    /// A `ui/message` waiting on the person's yes or no.
    private(set) var askedMessage: String?
    /// What the agent will be told with the person's next message, as the view last said.
    private(set) var contextLine: String?
    private(set) var title: String
    private(set) var prefersBorder = true

    @ObservationIgnored var actions: AppViewActions
    @ObservationIgnored weak var store: AppViewStore?
    @ObservationIgnored private(set) lazy var web: WKWebView = makeWebView()
    @ObservationIgnored private var delegate: AppViewDelegate?
    @ObservationIgnored private var feed = AppViewFeed()
    @ObservationIgnored private var policy = AppViewPolicy.strict
    @ObservationIgnored private var context: AppViewContext
    @ObservationIgnored private var messageID: JSONValue?
    @ObservationIgnored private var teardown: (id: JSONValue, done: CheckedContinuation<Void, Never>)?
    @ObservationIgnored private var nextRequest = 1
    @ObservationIgnored private var started = false

    static let maxInlineHeight: CGFloat = 640

    init(call: AppViewCall, actions: AppViewActions, store: AppViewStore) {
        self.call = call
        self.actions = actions
        self.store = store
        self.title = Self.title(for: call)
        #if os(macOS)
        let platform = AppViewContext.Platform.desktop
        #else
        let platform = AppViewContext.Platform.mobile
        #endif
        self.context = AppViewContext(theme: "light", platform: platform, width: 600,
                                      maxHeight: Self.maxInlineHeight, touch: platform == .mobile,
                                      hover: platform == .desktop,
                                      toolInfo: ["tool": ["name": .string(call.tool)]])
    }

    var isFullscreen: Bool { store?.fullscreen == call.id }

    static func title(for call: AppViewCall) -> String {
        if call.resourceURI == "ui://agents/dashboard" { return "Dashboard" }
        if call.tool == "show_test_view" { return "Test view" }
        return call.tool.replacingOccurrences(of: "_", with: " ")
    }

    // MARK: Loading

    /// Read the resource and draw it. Once.
    func start() {
        guard !started else { return }
        started = true
        Task { await load() }
    }

    private func load() async {
        let resource: DaemonAPI.ViewResource
        do {
            let value = try await actions.call(DaemonAPI.Method.viewsRead,
                                               try JSONValue.encoding(DaemonAPI.ViewReadRequest(agentID: actions.agentID,
                                                                                                uri: call.resourceURI)))
            resource = try value.decode(DaemonAPI.ViewResource.self)
        } catch {
            phase = .failed("This view could not be read from the server: \(Self.words(error))")
            return
        }
        policy = resource.policy
        prefersBorder = resource.prefersBorder ?? true
        // The network side of the policy, before anything is drawn. Never drawn without it.
        guard let rules = try? await WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: policy.rulesIdentifier, encodedContentRuleList: policy.contentRules) else {
            phase = .failed("This view could not be drawn safely, so it is not drawn.")
            return
        }
        guard phase != .gone else { return }
        web.configuration.userContentController.add(rules)
        let page = AppViewShell.page(html: resource.html, policy: policy)
        let response = HTTPURLResponse(url: AppViewShell.address, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "text/html; charset=utf-8",
                                                      "Content-Security-Policy": policy.header,
                                                      "Cache-Control": "no-store"])!
        web.loadSimulatedRequest(URLRequest(url: AppViewShell.address), response: response,
                                 responseData: Data(page.utf8))
        phase = .ready
    }

    private func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // Nothing kept, and nothing of the app's: a store of its own, gone with the view.
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.setURLSchemeHandler(AppViewRefusal(), forURLScheme: AppViewShell.scheme)
        #if os(iOS)
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.dataDetectorTypes = []
        #endif
        let delegate = AppViewDelegate(host: self)
        self.delegate = delegate
        // The bridge and its one handler live in a world of the app's own; the view's
        // frames are in the page's world, where neither exists.
        let world = WKContentWorld.world(name: AppViewShell.world)
        configuration.userContentController.add(delegate, contentWorld: world, name: AppViewShell.handler)
        configuration.userContentController.addUserScript(
            WKUserScript(source: AppViewShell.bridgeScript, injectionTime: .atDocumentEnd,
                         forMainFrameOnly: true, in: world))
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.navigationDelegate = delegate
        web.uiDelegate = delegate
        #if os(iOS)
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.backgroundColor = .clear
        web.scrollView.isScrollEnabled = false
        #endif
        return web
    }

    // MARK: Where it is drawn

    /// The call as it now stands: its result or its cancellation goes to the view.
    func update(_ call: AppViewCall) {
        guard call != self.call else { return }
        self.call = call
        for message in feed.due(call) { send(message) }
    }

    /// The space it has, and the look: told to the view when either changes.
    func place(width: CGFloat, height: CGFloat?, theme: ColorScheme,
               safeArea: (top: Double, right: Double, bottom: Double, left: Double) = (0, 0, 0, 0)) {
        var next = context
        next.width = Double(width)
        next.theme = theme == .dark ? "dark" : "light"
        if let height {
            next.displayMode = "fullscreen"
            next.height = Double(height)
            next.maxHeight = nil
        } else {
            next.displayMode = "inline"
            next.height = nil
            next.maxHeight = Self.maxInlineHeight
        }
        next.safeAreaInsets = safeArea
        let changes = next.changes(since: context)
        context = next
        if let changes, feed.initialized {
            send(AppViewBridge.notification("ui/notifications/host-context-changed", changes))
        }
    }

    // MARK: The person's answers

    func answerMessage(send: Bool) {
        guard let text = askedMessage, let id = messageID else { return }
        askedMessage = nil
        messageID = nil
        guard send else {
            self.send(AppViewBridge.error(id, code: -32000, "The person did not send it."))
            return
        }
        Task {
            let sent = await actions.send(text)
            self.send(sent ? AppViewBridge.result(id) : AppViewBridge.error(id, code: -32000, "It could not be sent."))
        }
    }

    func dropContext() {
        contextLine = nil
        Task {
            _ = try? await actions.call(DaemonAPI.Method.viewsContext, try JSONValue.encoding(
                DaemonAPI.ViewContextRequest(agentID: actions.agentID, viewID: call.id, uri: call.resourceURI)))
        }
    }

    func setFullscreen(_ on: Bool) {
        store?.fullscreen = on ? call.id : (store?.fullscreen == call.id ? nil : store?.fullscreen)
    }

    // MARK: Teardown

    /// Tell the view it is going, wait a moment for it to say it is ready, and take it down.
    func tearDown(reason: String) async {
        guard phase != .gone else { return }
        if feed.initialized {
            let id = JSONValue.string("teardown-\(nextRequest)")
            nextRequest += 1
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                teardown = (id, done)
                send(AppViewBridge.request(id, "ui/resource-teardown", ["reason": .string(reason)]))
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(2))
                    self.finishTeardown()
                }
            }
        }
        phase = .gone
        web.stopLoading()
        web.configuration.userContentController.removeAllScriptMessageHandlers()
        web.configuration.userContentController.removeAllContentRuleLists()
        web.removeFromSuperview()
        delegate = nil
    }

    private func finishTeardown() {
        guard let pending = teardown else { return }
        teardown = nil
        pending.done.resume()
    }

    // MARK: The conversation

    private func send(_ message: JSONValue) {
        guard phase == .ready, let data = try? JSONEncoder().encode(message) else { return }
        let text = String(decoding: data, as: UTF8.self)
        web.callAsyncJavaScript("window.agentsSendToView(text)", arguments: ["text": text], in: nil,
                                in: .world(name: AppViewShell.world)) { _ in }
    }

    /// One message from the view, as text, from the bridge.
    func received(_ text: String) {
        guard phase == .ready, let message = try? JSONValue.parse(Data(text.utf8)) else { return }
        switch AppViewBridge.read(message) {
        case .initialize(let id):
            send(AppViewBridge.result(id, AppViewBridge.initializeResult(context, policy: policy)))
        case .initialized:
            for message in feed.viewInitialized(call) { send(message) }
        case .ping(let id):
            send(AppViewBridge.result(id))
        case .callTool(let id, let name, let arguments):
            relay(id, DaemonAPI.Method.viewsCall,
                  DaemonAPI.ViewCallRequest(agentID: actions.agentID, viewID: call.id, name: name, arguments: arguments))
        case .readResource(let id, let uri):
            Task {
                do {
                    let value = try await actions.call(DaemonAPI.Method.viewsRead, try JSONValue.encoding(
                        DaemonAPI.ViewReadRequest(agentID: actions.agentID, uri: uri)))
                    let resource = try value.decode(DaemonAPI.ViewResource.self)
                    send(AppViewBridge.result(id, ["contents": [["uri": .string(resource.uri),
                                                                 "mimeType": .string(resource.mimeType),
                                                                 "text": .string(resource.html)]]]))
                } catch {
                    send(AppViewBridge.error(id, code: -32000, Self.words(error)))
                }
            }
        case .openLink(let id, let url):
            actions.openLink(url)
            send(AppViewBridge.result(id))
        case .message(let id, let text):
            // Never sent on the view's say-so: the person is asked, under the view.
            if let earlier = messageID { send(AppViewBridge.error(earlier, code: -32000, "Another message replaced it.")) }
            messageID = id
            askedMessage = text
        case .updateContext(let id, let content, let structured):
            contextLine = AppViewBridge.contextPreface(viewTitle: title, content: content, structuredContent: structured)
                .map { _ in Self.contextWords(content, structured) }
            relay(id, DaemonAPI.Method.viewsContext,
                  DaemonAPI.ViewContextRequest(agentID: actions.agentID, viewID: call.id, uri: call.resourceURI,
                                               content: content, structuredContent: structured),
                  answer: { _ in [:] })
        case .displayMode(let id, let mode):
            if AppViewBridge.displayModes.contains(mode) { setFullscreen(mode == "fullscreen") }
            send(AppViewBridge.result(id, ["mode": .string(isFullscreen ? "fullscreen" : "inline")]))
        case .sizeChanged(_, let height):
            if let height, height > 0 { self.height = min(Self.maxInlineHeight, max(32, CGFloat(height))) }
        case .log(let level, let data):
            Task {
                _ = try? await actions.call(DaemonAPI.Method.viewsLog, try JSONValue.encoding(
                    DaemonAPI.ViewLogRequest(agentID: actions.agentID, viewID: call.id, level: level, data: data)))
            }
        case .answered(let id):
            if teardown?.id == id { finishTeardown() }
        case .unknown(let id, let method):
            send(AppViewBridge.error(id, code: -32601, "\(method) is not something this host does."))
        case .malformed(let id, let reason):
            send(AppViewBridge.error(id, code: -32602, reason))
        case .ignored:
            break
        }
    }

    private func relay(_ id: JSONValue, _ method: String, _ request: some Encodable & Sendable,
                       answer: @escaping (JSONValue) -> JSONValue = { $0 }) {
        Task {
            do {
                let value = try await actions.call(method, try JSONValue.encoding(request))
                send(AppViewBridge.result(id, answer(value)))
            } catch {
                send(AppViewBridge.error(id, code: -32000, Self.words(error)))
            }
        }
    }

    private static func contextWords(_ content: JSONValue?, _ structured: JSONValue?) -> String {
        let text = (content?.arrayValue ?? []).compactMap { $0["text"]?.stringValue }.joined(separator: " ")
        return text.isEmpty ? "what the view last showed" : text
    }

    static func words(_ error: any Error) -> String {
        (error as? JSONRPCError)?.message ?? error.localizedDescription
    }
}

/// The web view's delegate and the bridge's handler: weak to the host, which owns the web
/// view, so neither keeps the other.
@MainActor
private final class AppViewDelegate: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
    weak var host: AppViewHost?

    init(host: AppViewHost) { self.host = host }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        // Only the shell's own frame, in the app's world, ever reaches this.
        guard message.frameInfo.isMainFrame, let text = message.body as? String else { return }
        host?.received(text)
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 preferences: WKWebpagePreferences,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
        let url = action.request.url?.absoluteString ?? ""
        let isMain = action.targetFrame?.isMainFrame ?? true
        // The shell, loaded by the app, and the view's own frame. Nothing else, ever: a view
        // opens a link by asking (`ui/open-link`), not by going there.
        if isMain, url == AppViewShell.address.absoluteString, action.navigationType == .other || action.navigationType == .reload {
            decisionHandler(.allow, preferences)
        } else if !isMain, url == "about:srcdoc" {
            decisionHandler(.allow, preferences)
        } else {
            decisionHandler(.cancel, preferences)
        }
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        nil
    }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void) {
        decisionHandler(.deny)
    }
}

/// The shell's scheme, answering nothing: a view that asks it for a file is refused.
private final class AppViewRefusal: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        task.didFailWithError(URLError(.resourceUnavailable))
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}
