import AgentsKitCore
import SwiftUI

/// A pinned `ui://` view (#189), open in the chat's place: the view drawn full page, fed by
/// the call its pin names. Opening it makes that call afresh, so the view is as of now.
///
/// Our extension of MCP Apps: SEP-1865 ties a view to a call the model made, and a pin is
/// the host making that call itself. There is no agent here, so the view's `ui/message` and
/// `ui/update-model-context` are refused (`AppViewActions.folder`). Its `agents/start-agent`
/// opens the form in this folder, as it would from a chat, and its `agents/message-agent`
/// goes to the session on the branch it names (#837).
struct PinnedViewPage: View {
    let folder: URL
    let pin: PinView
    let view: ViewPin
    /// One of `views/*`, to the host the folder is on.
    var call: @MainActor (String, JSONValue) async throws -> JSONValue
    /// Unpin, or Hide for a server's list view (#2032).
    var unpin: @MainActor () async -> Void
    /// The new-agent form in this folder, filled in by the view (#834).
    var startAgent: (@MainActor (AppViewStart) -> String?)? = nil
    /// The session on a branch in this folder, and a send to it (#837).
    var recipient: (@MainActor (AppViewAgentMessage) -> AppViewRecipient?)? = nil
    var sendTo: (@MainActor (UUID, String) async -> Bool)? = nil
    /// Whether the link to the host is up. Coming back, a page whose call or read failed or
    /// never answered makes it again (#978).
    var connected = true

    @Environment(\.openURL) private var openURL
    @State private var store = AppViewStore()
    /// One id for the whole time this page is open: the view's call, and its place.
    @State private var place = UUID()
    @State private var answer: JSONValue?
    @State private var problem: String?
    /// Try Again and a reconnect make the feeding call again.
    @State private var attempt = 0
    /// A disappear came, and no appear since. On a push the iPhone can send a disappear
    /// before an appear (#1797) or after it (#2167) while the page stays on screen, so a
    /// disappear tears the view down only when, a moment later, it is in no window.
    @State private var closed = false
    /// Torn down: the next appear feeds it and draws it again.
    @State private var tornDown = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // Not a .task: a disappear cancels one, and a page still shown then never got its
        // answer and stayed on its input ("Listing…", #2167).
        .onChange(of: Feeding(view: view, attempt: attempt), initial: true) { _, feeding in
            Task { await feed(feeding) }
        }
        .onChange(of: connected) {
            guard connected else { return }
            if problem != nil || answer == nil { attempt += 1 }
            store.reconnected()
        }
        .onAppear {
            closed = false
            guard tornDown else { return }
            tornDown = false
            attempt += 1
        }
        .onDisappear {
            closed = true
            Task {
                try? await Task.sleep(for: .milliseconds(500))
                guard closed, !tornDown, !store.anyInWindow else { return }
                tornDown = true
                store.tearDownAll(reason: "The pinned view was closed.")
            }
        }
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
            Button(pin.isServerView ? "Hide" : "Unpin") { Task { await unpin() } }
                .buttonStyle(.paper)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder private var content: some View {
        if let reason = pin.missingReason {
            note("This view can't be drawn here: \(reason).")
        } else if let problem {
            VStack(alignment: .leading, spacing: 8) {
                Text(problem).appText(.supporting).foregroundStyle(.secondary)
                Button("Try Again") { attempt += 1 }.buttonStyle(.paper)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(24)
        } else {
            let host = store.host(for: fedCall, actions: actions)
            // A new host after a teardown is a new page, so it starts (#1797).
            AppViewPage(host: host).id(ObjectIdentifier(host))
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
        AppViewActions(agentID: place, folder: folder, call: call, send: { _ in false },
                       openLink: { openURL($0) }, startAgent: startAgent, recipient: recipient, sendTo: sendTo)
    }

    /// The host-made call: running with its input, then done with what the tool answered.
    private var fedCall: AppViewCall {
        AppViewCall(id: place, server: view.server, tool: view.tool, resourceURI: view.uri,
                    arguments: view.arguments, result: answer, state: answer == nil ? .running : .done)
    }

    private struct Feeding: Equatable {
        var view: ViewPin
        var attempt: Int
    }

    /// The feeding call, within its deadline (#978): one with no answer said so, with Try Again.
    /// An answer for an older feeding than the latest is dropped.
    private func feed(_ feeding: Feeding) async {
        guard pin.missingReason == nil else { return }
        problem = nil
        let call = call
        do {
            let params = try JSONValue.encoding(DaemonAPI.ViewCallRequest(
                agentID: place, viewID: place, name: view.tool, arguments: view.arguments, folder: folder, feed: true,
                server: view.server == AppTool.serverName ? nil : view.server))
            let value = try await AppViewLoad.answered(within: AppViewLoad.feedDeadline) {
                try await call(DaemonAPI.Method.viewsCall, params)
            }
            guard feeding == Feeding(view: view, attempt: attempt) else { return }
            answer = value
        } catch {
            guard feeding == Feeding(view: view, attempt: attempt) else { return }
            problem = "The view's call did not answer: \(AppViewHost.words(error))"
        }
    }
}
