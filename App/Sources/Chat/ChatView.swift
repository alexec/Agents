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
                CrowdMark()
                    .frame(width: 220)
                    .padding(.bottom, 28)
            }
            PromptBar()
            if agent == nil { Spacer(minLength: 0) }
        }
        .animation(.snappy(duration: 0.28), value: model.selection)
        .navigationTitle(agent?.title ?? "New agent")
        .navigationSubtitle(agent.map { $0.cwd.lastPathComponent } ?? "")
    }
}
