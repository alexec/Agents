import AgentsKit
import SwiftUI

/// The right-hand side, whether or not there is an agent yet.
///
/// One view rather than two, because a new chat has to turn into the chat. The prompt
/// bar sits in the middle of an empty pane and moves to the foot of it when the
/// conversation starts, and it is the same bar throughout.
///
/// Once there is a conversation the bar floats: the transcript runs the full height of
/// the pane and scrolls underneath it, the way controls sit over content everywhere
/// else on the system. The transcript is told how tall the bar is so the last thing an
/// agent said can still be scrolled clear of it.
struct ChatView: View {
    @Environment(AppModel.self) private var model
    @State private var formHeight: CGFloat = 0

    private var agent: Agent? { model.selectedAgent }

    var body: some View {
        Group {
            if let agent {
                ZStack(alignment: .bottom) {
                    Transcript(agent: agent, bottomInset: formHeight)
                    form
                }
            } else {
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    CrowdMark()
                        .frame(width: 220)
                        .padding(.bottom, 28)
                    form
                    Spacer(minLength: 0)
                }
            }
        }
        .animation(.snappy(duration: 0.28), value: model.selection)
        .navigationTitle(agent?.title ?? "New agent")
        // One click, and back to the project. The context menu on the card has the same
        // word; this is for when you are already reading the thing you are putting away.
        .toolbar {
            if let agent, agent.state != .archived {
                ToolbarItem(placement: .automatic) {
                    Button {
                        Task {
                            await model.archive(agent.id)
                            model.selection = nil
                        }
                    } label: {
                        Label("Archive", systemImage: "archivebox")
                    }
                    .help("Archive this chat and go back to the project")
                }
            }
        }
        .navigationSubtitle(agent.map { $0.cwd.lastPathComponent } ?? "")
    }

    private var form: some View {
        VStack(spacing: 12) {
            if let request = model.permissionForSelection {
                PermissionView(request: request)
            }
            // A form waits the same way a permission question does, and floats with it.
            if let request = model.elicitationForSelection {
                // A fresh card per form, so the answers and the step reached on one
                // are not carried into the next.
                ElicitationView(request: request)
                    .id(request.id)
            }
            PromptBar()
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { formHeight = $0 }
    }
}
