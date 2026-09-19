import AgentsKit
import SwiftUI
import WebKit

/// A page beside the conversation.
///
/// The user drives it. The agent cannot navigate it, and nothing in this app does on an
/// agent's behalf (FR-035). It is a viewing surface for local servers and documentation,
/// not a replacement for Safari: no tabs, no bookmarks, no downloads.
struct BrowserPane: View {
    @Environment(AppModel.self) private var model
    let agent: Agent
    let state: AgentPaneState

    @Environment(WebHolders.self) private var holders
    @State private var typed = ""

    /// Held outside the view tree and keyed by agent, so switching agents and coming
    /// back finds the same page, history and scroll position (FR-031). A `@State`
    /// here would be remade every time the pane's identity changed, which is exactly
    /// what FR-031 says must not happen.
    private var web: WebHolder { holders.holder(for: agent.id) }

    var body: some View {
        VStack(spacing: 0) {
            bar
            Divider()
            ZStack {
                WebViewHost(holder: web) { url in
                    state.browserURL = url
                    typed = url?.absoluteString ?? typed
                }
                if let failure = web.failure {
                    Failed(message: failure) { web.reload() }
                }
                if state.browserURL == nil, web.failure == nil {
                    Empty(folder: agent.cwd.lastPathComponent)
                }
            }
        }
        .task(id: agent.id) {
            // The same page after switching agents and coming back (FR-031). The view
            // itself is held per agent, so its history and scroll position survive too.
            if let url = state.browserURL, web.current == nil {
                web.load(url)
                typed = url.absoluteString
            }
        }
    }

    private var bar: some View {
        HStack(spacing: 6) {
            Button { web.goBack() } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.borderless)
                .disabled(!web.canGoBack)
            Button { web.goForward() } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.borderless)
                .disabled(!web.canGoForward)
            Button { web.reload() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .disabled(state.browserURL == nil)

            TextField("localhost:3000", text: $typed)
                .textFieldStyle(.roundedBorder)
                .font(.callout)
                .onSubmit(go)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private func go() {
        guard let url = BrowserPolicy.url(fromTyped: typed) else {
            web.failure = "That is not an address this can open."
            return
        }
        switch BrowserPolicy.decide(url) {
        case .allow:
            state.browserURL = url
            web.load(url)
        case .refuse(let message):
            web.failure = message
        }
    }
}

/// What the pane says before it has been pointed anywhere.
private struct Empty: View {
    let folder: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "globe")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text("Nothing loaded")
                .font(.headline)
            Text("Type an address above. If the agent started a server in \(folder), this is where to look at it.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}

/// What failed, in plain words, with an offer to try again. Never a blank panel
/// (FR-032).
private struct Failed: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Try again", action: retry)
                .controlSize(.small)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}

/// One web view per agent, for the life of the window.
@MainActor
@Observable
final class WebHolders {
    private var holders: [UUID: WebHolder] = [:]

    func holder(for agentID: UUID) -> WebHolder {
        if let existing = holders[agentID] { return existing }
        let fresh = WebHolder()
        holders[agentID] = fresh
        return fresh
    }
}

/// Holds the web view outside the SwiftUI view tree.
///
/// SwiftUI makes and remakes its views freely, and a recreated `WKWebView` reloads the
/// page and loses the scroll position and any form state. Keeping it here means moving
/// between panes costs nothing (FR-031).
@MainActor
@Observable
final class WebHolder {
    var canGoBack = false
    var canGoForward = false
    var failure: String?
    private(set) var current: URL?

    @ObservationIgnored lazy var view: WKWebView = {
        let configuration = WKWebViewConfiguration()
        // Its own store, so a login to a local dev server survives a restart without
        // touching anything else. FR-033 needs no work beyond this: a WKWebView in this
        // app has no access to Safari's cookies, history or passwords. They are
        // different applications with different containers, and there is nothing to
        // opt out of.
        configuration.websiteDataStore = .default()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.allowsBackForwardNavigationGestures = true
        return view
    }()

    func load(_ url: URL) {
        failure = nil
        current = url
        view.load(URLRequest(url: url))
    }

    func reload() {
        failure = nil
        if let current, view.url == nil {
            view.load(URLRequest(url: current))
        } else {
            view.reload()
        }
    }

    func goBack() { view.goBack() }
    func goForward() { view.goForward() }

    func refreshHistory() {
        canGoBack = view.canGoBack
        canGoForward = view.canGoForward
    }
}

/// The web view itself, with every delegate written to refuse.
private struct WebViewHost: NSViewRepresentable {
    let holder: WebHolder
    let onNavigated: (URL?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(holder: holder, onNavigated: onNavigated) }

    func makeNSView(context: Context) -> WKWebView {
        let view = holder.view
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let holder: WebHolder
        let onNavigated: (URL?) -> Void

        init(holder: WebHolder, onNavigated: @escaping (URL?) -> Void) {
            self.holder = holder
            self.onNavigated = onNavigated
        }

        // A page may not open a window of its own (FR-034).
        func webView(_ webView: WKWebView,
                     createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            nil
        }

        // Only the four schemes, and visibly refused otherwise.
        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            switch BrowserPolicy.decide(navigationAction.request.url) {
            case .allow:
                decisionHandler(.allow)
            case .refuse(let message):
                holder.failure = message
                decisionHandler(.cancel)
            }
        }

        // No downloads in this feature, by the spec's own assumption. Refused rather
        // than silently dropped, so the user is not left waiting for a file.
        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationResponse: WKNavigationResponse,
                     decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            guard navigationResponse.canShowMIMEType else {
                holder.failure = "This pane shows web pages. It does not download files."
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        // Asked, never granted (FR-034).
        func webView(_ webView: WKWebView,
                     requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                     initiatedByFrame frame: WKFrameInfo,
                     type: WKMediaCaptureType,
                     decisionHandler: @escaping (WKPermissionDecision) -> Void) {
            decisionHandler(.prompt)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            holder.refreshHistory()
            onNavigated(webView.url)
        }

        func webView(_ webView: WKWebView,
                     didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: any Error) {
            holder.failure = Self.describe(error)
            holder.refreshHistory()
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
            holder.failure = Self.describe(error)
        }

        /// The common ones in plain words. A local server that has stopped is the case
        /// this pane meets most, so it gets its own sentence.
        static func describe(_ error: any Error) -> String {
            let error = error as NSError
            guard error.domain == NSURLErrorDomain else { return error.localizedDescription }
            switch error.code {
            case NSURLErrorCannotConnectToHost:
                return "Nothing is answering there. If the agent was running a server, it may have stopped."
            case NSURLErrorCannotFindHost:
                return "That host could not be found."
            case NSURLErrorTimedOut:
                return "That took too long to answer."
            case NSURLErrorNotConnectedToInternet:
                return "This Mac is not on the network."
            case NSURLErrorCancelled:
                return "That load was stopped."
            default:
                return error.localizedDescription
            }
        }
    }
}
