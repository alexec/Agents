import AgentsKitCore
import SwiftUI

/// A shell in the selected project's folder (#418): the one Control-` opens on the Mac,
/// and the same shell.
///
/// Not an agent's. It is offered on every page of the project, and an agent open or not
/// makes no difference to where it is. Done puts it away and leaves it running; End
/// Shell is the one thing that ends it, as on the Mac.
struct ProjectTerminalSheet: View {
    @Environment(RemoteModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let folder: URL
    /// Set as End Shell ends it, so the screen going is not taken for one put away.
    @State private var ended = false

    private var name: String {
        model.work.projects.first { $0.folder == folder }?.name ?? folder.lastPathComponent
    }

    var body: some View {
        // Made here, with the folder, before the screen asks the model for it by id.
        let _ = model.projectShellClient(for: folder)
        NavigationStack {
            Group {
                if model.isAway {
                    // Away, as the panes: a shell streams too much for iCloud (046).
                    NeedsSameNetworkView()
                } else {
                    ShellScreen(id: ProjectShell.id(for: folder), shell: 0, isFront: true, isOpen: { !ended })
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) { StaleBanner() }
            .navigationTitle("Terminal")
            .navigationSubtitle(name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .keyboardShortcut("`", modifiers: .control)
                }
                ToolbarItem(placement: .destructiveAction) {
                    Button("End Shell", role: .destructive) {
                        let id = ProjectShell.id(for: folder)
                        ended = true
                        Task { await model.closeShell(agentID: id, shell: 0) }
                        dismiss()
                    }
                    .disabled(model.isStale)
                }
            }
        }
        .onDisappear { model.isTyping = false }
    }
}
