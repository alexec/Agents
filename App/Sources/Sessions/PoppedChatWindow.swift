import AgentsKitCore
import AppKit
import SwiftUI

/// A session in a window of its own (#826): its chat, its prompt and what it asks, and
/// nothing of the main window's sidebar or inspector. The main window's selection is
/// not touched by it.
///
/// It follows the session: archived, it says so and offers Bring Back, as the main
/// window's chat does; deleted, it says that instead of showing an empty chat.
struct PoppedChatWindow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.appearsActive) private var appearsActive
    /// The session, as the window was opened with it and is restored with it.
    let id: UUID?
    @State private var chat: PoppedChat?
    /// What a chat's views reach for in the main window. Here, none of it is drawn:
    /// a window of its own has no inspector, and its chat opens files in the editor.
    @State private var frame = SidebarFrame()
    @State private var states = SidebarStates()
    @State private var requests = WindowRequests()

    private var agent: Agent? { id.flatMap { model.work.agent($0) } }

    var body: some View {
        Group {
            if let chat, agent != nil {
                VStack(spacing: 0) {
                    ChatView()
                }
                .environment(\.poppedChat, chat)
            } else if chat?.looked == true || id == nil {
                ContentUnavailableView("This session was deleted", systemImage: "trash",
                                       description: Text("There is nothing left of it to show. Close this window."))
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .paperGround()
        .frame(minWidth: 420, minHeight: 360)
        .toolbar { toolbar }
        .navigationTitle(AppCheckout.windowTitle(agent?.title))
        .navigationSubtitle(agent.flatMap { model.work.project(ProjectKey(host: $0.host, folder: $0.projectFolder))?.name } ?? "")
        .focusedSceneValue(\.poppedChat, chat)
        .environment(frame)
        .environment(states)
        .environment(requests)
        .tint(Paper.accent)
        // A file a chat links to is on its host, as in the main window.
        .environment(\.openURL, OpenURLAction { url in
            guard url.isFileURL else { return .systemAction }
            model.open(url, on: agent?.host ?? .mac)
            return .handled
        })
        .chosenTextSize()
        .task(id: id) {
            guard let id, chat?.id != id else { return }
            if let chat { model.closePopout(chat) }
            chat = model.openPopout(id)
        }
        .onDisappear {
            if let chat { model.closePopout(chat) }
            chat = nil
        }
        // In front, it is the conversation being watched, and is read there (#70).
        .onChange(of: appearsActive, initial: true) {
            if let id { model.popout(id, isInFront: appearsActive) }
        }
    }

    /// Pin, Rename and Archive, as the main window's toolbar has them for its chat.
    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if let agent, let chat {
            ToolbarItemGroup {
                let pinned = model.isPinned(agent)
                Button {
                    Task { await model.setPinned(agent, !pinned) }
                } label: {
                    Label(pinned ? "Unpin" : "Pin", systemImage: pinned ? "pin.slash" : "pin")
                }
                .disabled(agent.state == .archived)
                .help(pinned ? "Take this session out of Pinned in the sidebar"
                             : "Keep this session in Pinned, at the top of the sidebar")
                Button {
                    chat.isRenaming = true
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
                .disabled(agent.state == .archived)
                .help("Give this session a title of your own, which the runtime's no longer replaces")
                .popover(isPresented: Binding(get: { chat.isRenaming }, set: { chat.isRenaming = $0 }),
                         arrowEdge: .bottom) {
                    RenameField(agent: agent)
                        .appText(.reading)
                        .frame(width: 320)
                        .padding(10)
                }
                if agent.state == .archived {
                    Button {
                        Task { await model.unarchive(agent.id) }
                    } label: {
                        Label("Bring Back", systemImage: "tray.and.arrow.up")
                    }
                    .help("Bring this session back from the archive (⌥⌘⌫)")
                } else {
                    // Archived, it stays open here, saying so: the window is closed by
                    // the person, not from under them.
                    Button {
                        Task { await model.archive(agent.id, andLeave: true) }
                    } label: {
                        Label("Archive", systemImage: "archivebox")
                    }
                    .help("Archive this session (⌥⌘⌫)")
                }
            }
        }
    }
}

extension FocusedValues {
    /// The session in the key window, when that is a window of its own (#826): what the
    /// Session menu acts on then, rather than the main window's selection.
    @Entry var poppedChat: PoppedChat?
}

extension AppModel {
    /// The main window, on this session: for what only it can show, such as a subagent's
    /// steps in the inspector (#826).
    func showInMainWindow(_ id: UUID) {
        openAgent(id)
        NSApp.windows.first { MainWindow.isMain($0) }?.makeKeyAndOrderFront(nil)
    }
}

/// Which of the app's windows is the main one: not Settings, and not a session's own.
enum MainWindow {
    /// The scene id of a session's own window (`AgentsApp`).
    static let poppedSceneID = "session"

    static func isMain(_ window: NSWindow) -> Bool {
        guard let identifier = window.identifier?.rawValue, window.canBecomeMain else { return false }
        return identifier.contains("AppWindow") && !identifier.hasPrefix(poppedSceneID)
    }
}
