import AgentsKitCore
import SwiftUI
import WebKit

/// An HTML file drawn as a page in the files pane (#67), on the Mac and the phone.
///
/// What an agent writes is untrusted, so the web view is given as little as a page can
/// be drawn with, and every one of these is a decision rather than a default:
/// - **No network.** A content rule list blocks every load but the page's own scheme
///   (and `data:`/`blob:`, which are in the page already). No remote stylesheet, font,
///   picture, script, fetch or socket, whether or not scripts run.
/// - **Files only through the host.** The page is put at `agents-page://folder/…` and
///   everything beside it is answered by `PageFiles`, which asks the host with
///   `files/read`, inside the scope `HTMLPageScope` checks, refusing `..`. There is no
///   `file:` access, so this is the same on this Mac and on a server.
/// - **No scripts** unless the person allows them for this file, and even then no
///   network and nothing kept.
/// - **Nothing kept.** A non-persistent data store: no cookies, storage or cache
///   outlive the view.
/// - **No navigation away.** The file is the only thing that loads in the main frame.
///   A link to another file opens that file in the pane; a web or mail link goes to the
///   Browser pane or the default app; anything else does nothing.
/// - **No bridge to native code.** No `WKScriptMessageHandler`, ever. The two scripts
///   the app runs itself (read and put back the scroll position across a reload) run
///   in the app's own content world, where the page cannot see or call them.
struct HTMLPage: View {
    let text: String
    /// The file, by its absolute path on its host.
    let path: String
    let scope: HTMLPageScope
    let allowsScripts: Bool
    /// Counted up on every folder event, so a rewritten stylesheet or picture beside the
    /// page is drawn again even when the page's own text has not changed.
    let folderEvent: Int
    /// `files/read`, on the host the agent is on.
    let read: @Sendable (String) async throws -> FileReading
    /// A link the person clicked, already decided.
    let follow: (HTMLPageScope.LinkDecision) -> Void

    @State private var failure: String?

    var body: some View {
        if let failure {
            VStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .appText(.title)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
                Text(failure)
                    .appText(.supporting)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            HTMLWebView(page: self, failed: { failure = $0 })
                .accessibilityLabel(URL(filePath: path).lastPathComponent)
        }
    }
}

/// The one web view, kept for as long as the page is on screen, so a rewrite of the
/// file reloads it in place rather than making a new one.
@MainActor
final class HTMLPageCoordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
    var page: HTMLPage
    var failed: (String) -> Void
    private let files = PageFiles()
    private(set) lazy var web: WKWebView = makeWebView()

    /// What is on screen, so an update that changes nothing loads nothing.
    private var shown: (text: String, path: String, scripts: Bool, event: Int)?
    /// Where the reader was before a reload, put back once it has drawn.
    private var keepScroll: (x: Double, y: Double)?
    /// Bumped by every load, so a slow scroll read from an earlier one is dropped.
    private var loads = 0
    /// The rule list blocking the network is on this view. Nothing loads until it is.
    private var blocksNetwork = false

    init(page: HTMLPage, failed: @escaping (String) -> Void) {
        self.page = page
        self.failed = failed
    }

    private func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // Nothing kept: cookies, local storage and cache go with the view.
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(files, forURLScheme: HTMLPageScope.scheme)
        // Scripts are decided per load, in `decidePolicyFor … preferences`. Off here
        // too, so nothing runs before the first decision.
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        #if os(iOS)
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.dataDetectorTypes = []
        #endif
        // No `userContentController.add(_:name:)`: the page has no way to reach the app.
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.navigationDelegate = self
        web.uiDelegate = self
        #if os(macOS)
        web.allowsMagnification = true
        #endif
        return web
    }

    /// Load the page when what it shows has changed: its text, whether scripts run, or a
    /// file beside it.
    func update(_ page: HTMLPage) {
        self.page = page
        files.scope = page.scope
        files.read = page.read
        let next = (text: page.text, path: page.path, scripts: page.allowsScripts, event: page.folderEvent)
        if let shown, shown == next { return }
        let samePage = shown?.path == next.path
        shown = next
        loads += 1
        let load = loads
        Task {
            if !blocksNetwork, let list = await Self.rules.value {
                web.configuration.userContentController.add(list)
                blocksNetwork = true
            }
            guard blocksNetwork else {
                // Never drawn without the block on the network.
                failed("This page could not be drawn safely, so it is not drawn. The source is one click away.")
                return
            }
            // The same file again keeps the reader's place; another file starts at the top.
            keepScroll = samePage ? await scrollPosition() : nil
            guard load == loads, let address = page.scope.address(of: page.path) else { return }
            web.loadSimulatedRequest(URLRequest(url: address), responseHTML: page.text)
        }
    }

    private func scrollPosition() async -> (x: Double, y: Double)? {
        guard web.url != nil,
              let pair = try? await web.evaluateJavaScript("[window.scrollX, window.scrollY]",
                                                           in: nil, contentWorld: .defaultClient) as? [Double],
              pair.count == 2 else { return nil }
        return (pair[0], pair[1])
    }

    /// Compiled once for every page the app draws.
    private static let rules = Task { @MainActor () -> WKContentRuleList? in
        try? await WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "agents-html-page-v1", encodedContentRuleList: HTMLPageScope.contentRules)
    }

    // MARK: Navigation

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 preferences: WKWebpagePreferences,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
        preferences.allowsContentJavaScript = page.allowsScripts
        let url = action.request.url
        let address = page.scope.address(of: page.path)
        let isMainFrame = action.targetFrame?.isMainFrame ?? true
        // The file itself, loaded by the app.
        if isMainFrame, action.navigationType == .other || action.navigationType == .reload,
           url == address {
            decisionHandler(.allow, preferences)
            return
        }
        // A frame inside the page may show another file beside it, through the scheme
        // handler, but nothing from anywhere else.
        if !isMainFrame {
            let inScope = url.map { (try? page.scope.path(for: $0).get()) != nil } ?? false
            decisionHandler(inScope || url?.absoluteString == "about:blank" ? .allow : .cancel, preferences)
            return
        }
        let decision = page.scope.decide(link: url, on: address ?? URL(string: "about:blank")!)
        if decision == .stay {
            decisionHandler(.allow, preferences)
            return
        }
        decisionHandler(.cancel, preferences)
        // Only what the person clicked goes anywhere. A script moving the page, or a form,
        // is stopped and goes nowhere.
        if action.navigationType == .linkActivated { page.follow(decision) }
    }

    // A link with a target of its own, or a script's window.open: the same as a click,
    // and never a second web view.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if action.navigationType == .linkActivated, let address = page.scope.address(of: page.path) {
            page.follow(page.scope.decide(link: action.request.url, on: address))
        }
        return nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let keep = keepScroll else { return }
        keepScroll = nil
        webView.evaluateJavaScript("window.scrollTo(\(keep.x), \(keep.y))", in: nil, in: .defaultClient) { _ in }
    }

    // Asked, never granted: a page has no business with the camera or microphone.
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void) {
        decisionHandler(.deny)
    }
}

/// Answers the page's requests for the files beside it, by asking the host.
@MainActor
final class PageFiles: NSObject, WKURLSchemeHandler {
    var scope = HTMLPageScope(root: "/")
    var read: @Sendable (String) async throws -> FileReading = { _ in throw CancellationError() }
    /// Requests still being answered. One WebKit has stopped is never answered: calling
    /// a stopped task raises.
    private var running: [ObjectIdentifier: Task<Void, Never>] = [:]

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        let id = ObjectIdentifier(task)
        guard let url = task.request.url else {
            task.didFailWithError(URLError(.badURL))
            return
        }
        let scope = scope, read = read
        running[id] = Task { @MainActor [weak self] in
            let answer = await scope.answer(url, read: read)
            guard let self, self.running.removeValue(forKey: id) != nil else { return }
            let status: Int, body: Data, type: String
            switch answer {
            case .file(let data, let mimeType, let isText):
                (status, body, type) = (200, data, isText ? "\(mimeType); charset=utf-8" : mimeType)
            case .refused(let code, let reason):
                (status, body, type) = (code, Data(reason.utf8), "text/plain; charset=utf-8")
            }
            // Never cached: a stylesheet the agent rewrites is read again on the reload.
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": type,
                                                          "Content-Length": "\(body.count)",
                                                          "Cache-Control": "no-store"])!
            task.didReceive(response)
            task.didReceive(body)
            task.didFinish()
        }
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {
        running.removeValue(forKey: ObjectIdentifier(task))?.cancel()
    }
}

#if os(macOS)
private struct HTMLWebView: NSViewRepresentable {
    let page: HTMLPage
    let failed: (String) -> Void

    func makeCoordinator() -> HTMLPageCoordinator { HTMLPageCoordinator(page: page, failed: failed) }

    func makeNSView(context: Context) -> WKWebView {
        context.coordinator.update(page)
        return context.coordinator.web
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.failed = failed
        context.coordinator.update(page)
    }
}
#else
private struct HTMLWebView: UIViewRepresentable {
    let page: HTMLPage
    let failed: (String) -> Void

    func makeCoordinator() -> HTMLPageCoordinator { HTMLPageCoordinator(page: page, failed: failed) }

    func makeUIView(context: Context) -> WKWebView {
        context.coordinator.update(page)
        return context.coordinator.web
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.failed = failed
        context.coordinator.update(page)
    }
}
#endif
