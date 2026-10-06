import AgentsKitCore
import SwiftUI

/// The project's Dashboard, drawn as `ui://agents/dashboard` (#188).
///
/// The same host a chat uses for a tool's view. The page makes the call itself: there is
/// no conversation to have called `read_dashboard`. The native tile page is not this
/// destination. Update now, the file note and the footer stay on the page, around the view.
/// Tile files, keepers and `take_over` are untouched.
struct ProjectDashboardView: View {
    let folder: URL
    let snapshot: DashboardSnapshot?
    /// Bumps when the host says the Dashboard changed, so the page asks again.
    var revision: Int
    var call: @MainActor (String, JSONValue) async throws -> JSONValue
    var refresh: @MainActor () async -> Void
    var openTarget: @MainActor (String, String) -> Void

    @Environment(\.openURL) private var openURL
    @State private var store = AppViewStore()
    /// One id for the whole time this page is open: the view, and the project place
    /// `views/read` is asked in. No conversation is required.
    @State private var place = UUID()

    var body: some View {
        let actions = AppViewActions(
            agentID: place,
            project: folder,
            call: call,
            send: { _ in false },
            openLink: { openURL($0) },
            openDashboardTarget: openTarget)
        VStack(alignment: .leading, spacing: 0) {
            AppViewPage(host: store.host(for: dashboardCall, actions: actions))
        }
        .task(id: revision) { await refresh() }
        .onDisappear { store.tearDownAll(reason: "The Dashboard was closed.") }
    }

    /// The host-made call. Its result is the snapshot the page already holds, said again
    /// when that snapshot changes.
    private var dashboardCall: AppViewCall {
        var call = AppViewCall(id: place, tool: "read_dashboard", resourceURI: "ui://agents/dashboard")
        if let snapshot, let structured = try? JSONValue.encoding(snapshot) {
            call.state = .done
            call.result = [
                "content": [["type": "text", "text": "Dashboard"]],
                "structuredContent": structured,
            ]
        }
        return call
    }
}
