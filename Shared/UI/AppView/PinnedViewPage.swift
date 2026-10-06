import AgentsKitCore
import SwiftUI

/// A pinned `ui://` view (#189), open in the chat's place: the view drawn full page, fed by
/// the call its pin names. Opening it makes that call afresh, so the view is as of now.
///
/// Our extension of MCP Apps: SEP-1865 ties a view to a call the model made, and a pin is
/// the host making that call itself. There is no agent here, so the view's `ui/message` and
/// `ui/update-model-context` are refused (`AppViewActions.project`).
struct PinnedViewPage: View {
    let folder: URL
    let pin: PinView
    let view: ViewPin
    /// One of `views/*`, to the host the project is on.
    var call: @MainActor (String, JSONValue) async throws -> JSONValue
    var unpin: @MainActor () async -> Void

    @Environment(\.openURL) private var openURL
    @State private var store = AppViewStore()
    /// One id for the whole time this page is open: the view's call, and its place.
    @State private var place = UUID()
    @State private var answer: JSONValue?
    @State private var problem: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: view) { await feed() }
        .onDisappear { store.tearDownAll(reason: "The pinned view was closed.") }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "square.grid.2x2")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(pin.title)
                    .appText(.reading).fontWeight(.semibold)
                    .lineLimit(1)
                Text(view.uri)
                    .appText(.fine)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button("Unpin") { Task { await unpin() } }
                .buttonStyle(.paper)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder private var content: some View {
        if let reason = pin.missingReason {
            note("This view can't be drawn here: \(reason).")
        } else if let problem {
            note(problem)
        } else {
            AppViewPage(host: store.host(for: fedCall, actions: actions))
        }
    }

    private func note(_ words: String) -> some View {
        Text(words)
            .appText(.supporting)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(24)
    }

    private var actions: AppViewActions {
        AppViewActions(agentID: place, project: folder, call: call, send: { _ in false },
                       openLink: { openURL($0) })
    }

    /// The host-made call: running with its input, then done with what the tool answered.
    private var fedCall: AppViewCall {
        AppViewCall(id: place, server: view.server, tool: view.tool, resourceURI: view.uri,
                    arguments: view.arguments, result: answer, state: answer == nil ? .running : .done)
    }

    private func feed() async {
        guard pin.missingReason == nil else { return }
        do {
            answer = try await call(DaemonAPI.Method.viewsCall, try JSONValue.encoding(DaemonAPI.ViewCallRequest(
                agentID: place, viewID: place, name: view.tool, arguments: view.arguments, project: folder, feed: true,
                server: view.server == AppTool.serverName ? nil : view.server)))
            problem = nil
        } catch {
            problem = "The view's call did not answer: \(AppViewHost.words(error))"
        }
    }
}
