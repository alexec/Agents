import AgentsKit
import SwiftUI

/// The right-hand side, whether or not there is an agent yet.
///
/// One view rather than two, because a new chat has to turn into the chat. The prompt
/// bar sits in the middle of an empty pane and moves to the foot of it when the
/// conversation starts, and it is the same bar throughout.
struct ChatView: View {
    @Environment(AppModel.self) private var model

    private var agent: Agent? { model.selectedAgent }

    var body: some View {
        VStack(spacing: 0) {
            if let agent {
                Transcript(agent: agent)
                if let request = model.permissionForSelection {
                    PermissionView(request: request)
                }
            } else {
                Spacer(minLength: 0)
                // The app's own icon rather than a copy of it, so it can never drift
                // from what is on the Dock.
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .frame(width: 148, height: 148)
                    .padding(.bottom, 20)
            }
            PromptBar()
            if agent == nil { Spacer(minLength: 0) }
        }
        .animation(.snappy(duration: 0.28), value: model.selection)
        .navigationTitle(agent?.title ?? "New agent")
        .navigationSubtitle(agent.map { $0.cwd.lastPathComponent } ?? "")
        .toolbar {
            if let agent {
                ToolbarItemGroup {
                    if agent.state.holdsRuntime {
                        Button("Stop") { Task { await model.stop(agent.id) } }
                    }
                    if agent.state == .archived {
                        Button("Bring back") { Task { await model.unarchive(agent.id) } }
                    } else {
                        Button("Archive") { Task { await model.archive(agent.id) } }
                    }
                }
            }
        }
    }
}
