import AgentsKitCore
import SwiftUI

/// An artifact in a window of its own (#3034), from Exchanged's "Open in New Window": read
/// without swapping the sidebar pane it came from, as a session's own window (#826) already
/// reads a chat without touching the main window's selection.
///
/// Scoped to `.file` and `.web`, the two destinations an artifact already opens somewhere
/// on tap; `.inPlace` and `.nowhere` have no window of their own, as they have no tap action
/// today either.
struct ArtifactWindowKey: Hashable, Codable {
    var agentID: UUID
    var name: String
    var destination: Destination

    enum Destination: Hashable, Codable {
        case file(URL)
        case web(URL)
    }

    init?(agentID: UUID, artifact: Artifact) {
        switch artifact.destination {
        case .file(let url): destination = .file(url)
        case .web(let url): destination = .web(url)
        case .inPlace, .nowhere: return nil
        }
        self.agentID = agentID
        name = artifact.name
    }
}

/// The scene id (`AgentsApp`): what opens an artifact's window again by, and what `Window ▸`
/// restores at launch.
enum ArtifactWindowScene {
    static let id = "artifact"
}

struct ArtifactWindow: View {
    @Environment(AppModel.self) private var model
    /// The artifact, as the window was opened with it and is restored with it.
    let key: ArtifactWindowKey?
    /// Its own frame and panes, so this window's Files tree and Browser page are not the
    /// main window's, nor one folder window's (#1089): a reader of its own.
    @State private var frame = SidebarFrame(keyedBy: "artifact")
    @State private var states = SidebarStates()
    @State private var webHolders = WebHolders()

    private var agent: Agent? { key.flatMap { model.work.agent($0.agentID) } }

    var body: some View {
        Group {
            if let key, let agent {
                content(key: key, agent: agent)
            } else {
                ContentUnavailableView("This session is gone", systemImage: "questionmark.folder",
                                       description: Text("Close this window."))
            }
        }
        .paperGround()
        .frame(minWidth: 480, minHeight: 360)
        .navigationTitle(AppCheckout.windowTitle(key?.name))
        .tint(Paper.accent)
        .environment(frame)
        .environment(states)
        .environment(webHolders)
    }

    @ViewBuilder
    private func content(key: ArtifactWindowKey, agent: Agent) -> some View {
        let state = states.state(for: agent.id)
        switch key.destination {
        case .file(let url):
            FilesPane(agent: agent, state: state)
                .task(id: url) {
                    state.folder = url.deletingLastPathComponent()
                    state.openFile = url
                    state.openLine = nil
                    frame.pane = .files
                }
        case .web(let url):
            BrowserPane(agent: agent, state: state)
                .task(id: url) {
                    // Loaded directly, not left to `BrowserPane`'s own mount-time task: that
                    // one looks once, on `agent.id`, and may run before this sets `browserURL`.
                    state.browserURL = url
                    webHolders.holder(for: agent.id).load(url)
                }
        }
    }
}
