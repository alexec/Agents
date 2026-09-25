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
    @Environment(SidebarFrame.self) private var frame
    @Environment(SidebarStates.self) private var states
    @State private var formHeight: CGFloat = 0

    private var agent: Agent? { model.selectedAgent }

    var body: some View {
        Group {
            if let agent {
                ZStack(alignment: .bottom) {
                    Transcript(agent: agent, bottomInset: formHeight)
                        // Over the chat rather than in the toolbar, whose trailing end
                        // is above the sidebar whenever the sidebar is open. The
                        // transcript scrolls on under it, as it does under the prompt.
                        .safeAreaInset(edge: .top, spacing: 0) { actions(for: agent) }
                    form
                }
                // Back to the project the way Safari goes back a page.
                .swipeBack { model.selection = nil }
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
        .navigationSubtitle(agent.map { $0.cwd.lastPathComponent } ?? "")
        .environment(\.chatActions, chatActions)
    }

    /// What the shared chat rows mean on a Mac (033).
    private var chatActions: ChatActions {
        ChatActions(
            // The editor the Mac opens that file with, which is the one the user chose.
            open: { location in NSWorkspace.shared.open(URL(filePath: location.path)) },
            terminalOutput: { [model] id in model.terminalOutput[id] ?? "" },
            unqueue: { [model] prompt, agentID in await model.unqueue(prompt, from: agentID) },
            // The sidebar's Changes pane, open at that edit (035 FR-014).
            showEdit: { [frame, states, agent] diff, toolCallID in
                guard let agent else { return }
                states.state(for: agent.id).changesSelection = ChangesSelection(
                    path: ReportedChanges.key(diff.path), toolCallID: toolCallID)
                frame.pane = .changes
                if !frame.isOpen { frame.open() }
            })
    }

    /// What can be done to the chat as a whole, at the right-hand edge of its column.
    @ViewBuilder
    private func actions(for agent: Agent) -> some View {
        if model.canStop(agent) || agent.state != .archived {
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                // Beside Archive, and unlike it the page stays: someone who stops a chat
                // that has gone the wrong way wants to keep reading it and say what next.
                // ⌘. lives on the button, so it exists exactly when the button does.
                if model.canStop(agent) {
                    Button {
                        Task { await model.stop(agent.id) }
                    } label: {
                        Label("Stop", systemImage: "stop.circle")
                    }
                    .buttonStyle(.paper)
                    .appText(.fine)
                    .keyboardShortcut(".", modifiers: .command)
                    .help("Stop this agent and stay on the chat")
                }
                // One click, and back to the project. The context menu on the card has
                // the same word; this is for when you are already reading the thing you
                // are putting away.
                if agent.state != .archived {
                    Button {
                        Task {
                            await model.archive(agent.id)
                            model.selection = nil
                        }
                    } label: {
                        Label("Archive", systemImage: "archivebox")
                    }
                    .buttonStyle(.paper)
                    .appText(.fine)
                    .help("Archive this chat and go back to the project")
                }
            }
            .chatColumn()
            .padding(.vertical, 8)
        }
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
