import AgentsKitCore
import SwiftUI

/// The selected project's shells, in its own folder (#418): the ones Control-` opens
/// on the Mac, the same shells, one to a tab as there.
///
/// Not an agent's. It is offered on every page of the project, and an agent open or not
/// makes no difference to where they are. Done puts them away and leaves them running;
/// closing a tab ends its shell, and End Shell ends the one in front, as on the Mac.
struct ProjectTerminalSheet: View {
    @Environment(RemoteModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let folder: URL
    @State private var shells = [0]
    @State private var front = 0
    @State private var canOpenMore = true

    private var id: UUID { ProjectShell.id(for: folder) }

    private var name: String {
        model.work.projects.first { $0.folder == folder }?.name ?? folder.lastPathComponent
    }

    var body: some View {
        NavigationStack {
            Group {
                if model.isAway {
                    // Away, as the panes: a shell streams too much for iCloud (046).
                    NeedsSameNetworkView()
                } else {
                    VStack(spacing: 0) {
                        ShellTabs(shells: shells, titles: titles, front: front,
                                  canOpenMore: canOpenMore && !model.isStale,
                                  select: { front = $0 }, open: open, close: close)
                        Divider()
                        ZStack {
                            ForEach(shells, id: \.self) { shell in
                                // Made here, with the folder, before the screen asks the
                                // model for it by id.
                                let _ = model.projectShellClient(for: folder, shell: shell)
                                ShellScreen(id: id, shell: shell, isFront: front == shell,
                                            isOpen: { shells.contains(shell) })
                                    .opacity(front == shell ? 1 : 0)
                                    .allowsHitTesting(front == shell)
                                    .accessibilityHidden(front != shell)
                            }
                        }
                    }
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
                    Button("End Shell", role: .destructive) { close(front) }
                        .disabled(model.isStale)
                }
            }
        }
        // The tabs the Mac's panel has, found each time the sheet opens.
        .task {
            guard let held = await model.projectShellNumbers(for: folder) else {
                canOpenMore = false
                return
            }
            shells = held.isEmpty ? [0] : held
            if !shells.contains(front) { front = shells.first ?? 0 }
        }
        .onDisappear { model.isTyping = false }
    }

    /// What the program in each tab calls it, when it says.
    private var titles: [Int: String] {
        var titles: [Int: String] = [:]
        for shell in shells {
            if let title = model.projectShellClient(for: folder, shell: shell).title { titles[shell] = title }
        }
        return titles
    }

    /// The host numbers the new shell, so a tab opened on the Mac at the same moment
    /// never gets the same one.
    private func open() {
        Task {
            let next = await model.openProjectShell(for: folder) ?? ((shells.max() ?? -1) + 1)
            if !shells.contains(next) { shells.append(next) }
            front = next
        }
    }

    /// Closing a tab ends its shell, on the Mac too. Closing the last puts the sheet away.
    private func close(_ shell: Int) {
        guard let index = shells.firstIndex(of: shell) else { return }
        shells.remove(at: index)
        Task { await model.closeShell(agentID: id, shell: shell) }
        if shells.isEmpty {
            dismiss()
        } else if front == shell {
            front = shells[min(index, shells.count - 1)]
        }
    }
}
