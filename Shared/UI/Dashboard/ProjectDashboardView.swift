import AgentsKitCore
import SwiftUI

/// The project's Dashboard, drawn as `ui://agents/dashboard` (#188).
///
/// The same host a chat uses for a tool's view. The page makes the call itself: there is
/// no conversation to have called `read_dashboard`. The native tile page is not this
/// destination. Update now, the file note and the footer stay on the page, around the view.
/// Tile files, keepers and `take_over` are untouched.
struct ProjectDashboardView: View {
    let snapshot: DashboardSnapshot?
    /// Bumps when the host says the Dashboard changed, so the page asks again.
    var revision: Int
    var call: @MainActor (String, JSONValue) async throws -> JSONValue
    var refresh: @MainActor () async -> Void
    var update: @MainActor () async -> Void

    @Environment(\.openURL) private var openURL
    @State private var store = AppViewStore()
    /// One id for the whole time this page is open: the view, and the project place
    /// `views/read` is asked in. No conversation is required.
    @State private var place = UUID()

    var body: some View {
        let actions = AppViewActions(
            agentID: place,
            call: call,
            send: { _ in false },
            openLink: { openURL($0) })
        VStack(alignment: .leading, spacing: 0) {
            heading
            AppViewPage(host: store.host(for: dashboardCall, actions: actions))
            Text(DashboardModel.filesSentence + ".")
                .appText(.fine)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
        }
        .task(id: revision) { await refresh() }
        .onDisappear { store.tearDownAll(reason: "The Dashboard was closed.") }
        .toolbar { updateButton }
    }

    @ViewBuilder
    private var heading: some View {
        if snapshot?.update != nil || snapshot?.note != nil {
            VStack(alignment: .leading, spacing: 4) {
                if let update = snapshot?.update {
                    TimelineView(.periodic(from: .now, by: 15)) { context in
                        if let line = update.line(now: context.date) {
                            Text(line).appText(.fine).foregroundStyle(.secondary)
                        }
                    }
                }
                if let note = snapshot?.note {
                    Label(note, systemImage: "exclamationmark.triangle")
                        .appText(.fine)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ToolbarContentBuilder
    private var updateButton: some ToolbarContent {
        if let update = snapshot?.update {
            ToolbarItem(placement: .primaryAction) {
                TimelineView(.periodic(from: .now, by: 15)) { context in
                    Button {
                        Task { await self.update() }
                    } label: {
                        if update.isRunning {
                            ProgressView()
                        } else {
                            Label("Update now", systemImage: "arrow.clockwise")
                        }
                    }
                    .disabled(!update.canPress(now: context.date))
                    .help(update.line(now: context.date) ?? "Update now")
                }
            }
        }
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
