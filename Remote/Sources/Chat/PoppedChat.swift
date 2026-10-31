import AgentsKitCore
import Foundation
import SwiftUI
import UIKit

/// A session open in a scene of its own on an iPad (#888), as the Mac's window of its
/// own (#826): beside the main scene in Stage Manager or Split View, or on another
/// screen.
///
/// The main scene's model holds one page of one transcript, the selected chat's. This
/// holds a second page, of this session only, so the two can be read at once. The
/// session itself, its questions and its marks are still the model's: one record of
/// each, so a question answered in one scene leaves the other with it.
@MainActor @Observable
final class PoppedChat {
    let id: UUID
    /// Its transcript, and only that: a model of its own that watches this one session.
    let work = AgentsModel()
    /// Bumped when something asks this scene's chat to go to its end.
    private(set) var scrollToEndToken = 0
    /// Whether it has been looked for once. Until then, a session not in hand is one
    /// still on its way (a scene restored at launch), not one that has gone.
    var looked = false
    /// How many scenes show it. One, unless the system restores a second.
    @ObservationIgnored var scenes = 0
    @ObservationIgnored var isLoadingEarlier = false

    init(id: UUID) {
        self.id = id
        work.watching = id
    }

    func scrollToEnd() { scrollToEndToken += 1 }

    /// The scene a session opens in (`RemoteApp`).
    static let sceneID = "session"
    /// What a session dragged out of the sidebar carries, to open a scene of its own.
    /// Listed under `NSUserActivityTypes`.
    static let activityType = "com.alexecollins.agents.remote.session"

    /// A session's row, dragged: lifted out of the sidebar, it opens a scene of its own.
    static func itemProvider(for agent: Agent) -> NSItemProvider {
        let activity = NSUserActivity(activityType: activityType)
        activity.title = agent.title
        // What the session's scene, and only it, says it handles.
        activity.targetContentIdentifier = activityType
        activity.userInfo = ["agentID": agent.id.uuidString]
        let provider = NSItemProvider()
        provider.registerObject(activity, visibility: .all)
        provider.suggestedName = agent.title
        return provider
    }

    static func agentID(in activity: NSUserActivity) -> UUID? {
        (activity.userInfo?["agentID"] as? String).flatMap(UUID.init(uuidString:))
    }
}

extension EnvironmentValues {
    /// The session this chat is in a scene of its own for (#888); nil in the main scene,
    /// whose chat is the selection.
    @Entry var poppedChat: PoppedChat? = nil
    /// Opens the folder's own shell (#418) from the chat's ··· menu (#2808); nil where the
    /// chat has none, as in a scene of its own.
    @Entry var openFolderTerminal: OpenFolderTerminal? = nil
}

/// Opens a folder's own shell (#418). Told apart by the folder, not the closure, so a
/// chat is not drawn again each time the scene is (#2808).
struct OpenFolderTerminal: Equatable {
    let folder: URL
    let open: @MainActor () -> Void

    @MainActor func callAsFunction() { open() }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.folder == rhs.folder }
}

/// A session in a scene of its own (#888): its chat, its prompt, what it asks and its
/// panes, and nothing of the main scene's sidebar. The main scene's selection is not
/// touched by it.
///
/// It follows the session: archived, it says so and offers Unarchive, as the main
/// scene's chat does; deleted, it says that instead of showing an empty chat.
struct PoppedChatScene: View {
    @Environment(RemoteModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    /// The session, as the scene was opened with it and is restored with it. A drag out
    /// of the sidebar opens the scene first and names the session after.
    @Binding var id: UUID?
    @State private var chat: PoppedChat?
    /// This scene, among the app's, for where the person is (021).
    @State private var sceneID = UUID()

    private var agent: Agent? { id.flatMap { model.work.agent($0) } }

    var body: some View {
        NavigationStack {
            Group {
                if let chat, agent != nil {
                    RemoteChatView()
                        .paperGround()
                        .environment(\.poppedChat, chat)
                } else if chat?.looked == true {
                    SessionDeletedPage(next: .closeWindow)
                } else if let chat, let failure = chat.work.transcriptLoadFailure {
                    // Not looked for: its host did not answer, so it is not called deleted (#2743).
                    SessionNotLoadedPage(failure: failure) { await model.loadTranscript(of: chat) }
                } else if id == nil {
                    ContentUnavailableView("No session", systemImage: "bubble.left.and.bubble.right",
                                           description: Text("Drag a session out of the sidebar to open it here."))
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .background(Paper.ground)
        .onContinueUserActivity(PoppedChat.activityType) { activity in
            if let dragged = PoppedChat.agentID(in: activity) { id = dragged }
        }
        .task(id: id) {
            guard let id, chat?.id != id else { return }
            if let chat { model.closePopout(chat) }
            chat = model.openPopout(id)
            // Restored on its own, with no main scene to start the link.
            Task { await model.connect() }
        }
        .onDisappear {
            if let chat { model.closePopout(chat) }
            chat = nil
        }
        // The key window's chat is the one being watched, and is read there (#70).
        .onKeyWindowChange { isKey in
            if let id { model.popout(id, isInFront: isKey) }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in model.scenePhase(phase, of: sceneID) }
    }
}

/// Open in New Window (#888): a session in a scene of its own, where the device has
/// more than one. An iPhone has one, so it is not offered there, by design.
struct OpenInNewWindowButton: View {
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows
    @Environment(\.openWindow) private var openWindow
    let agent: Agent

    var body: some View {
        if supportsMultipleWindows {
            Button("Open in New Window", systemImage: "macwindow.badge.plus") {
                openWindow(id: PoppedChat.sceneID, value: agent.id)
            }
        }
    }
}

extension View {
    /// Told whether this view's window is the key window, as it changes: on an iPad
    /// with several scenes in front, the one the person last touched (#888).
    func onKeyWindowChange(_ action: @escaping (Bool) -> Void) -> some View {
        background(KeyWindowReader(changed: action).frame(width: 0, height: 0).accessibilityHidden(true))
    }

    /// A session's row, draggable out of the sidebar into a scene of its own (#888), where
    /// the device has more than one.
    func draggableToNewWindow(_ agent: Agent) -> some View {
        modifier(DraggableToNewWindow(agent: agent))
    }
}

private struct DraggableToNewWindow: ViewModifier {
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows
    let agent: Agent

    func body(content: Content) -> some View {
        if supportsMultipleWindows {
            content.onDrag { PoppedChat.itemProvider(for: agent) }
        } else {
            content
        }
    }
}

private struct KeyWindowReader: UIViewRepresentable {
    let changed: (Bool) -> Void

    func makeUIView(context: Context) -> Watcher {
        let view = Watcher()
        view.changed = changed
        return view
    }

    func updateUIView(_ view: Watcher, context: Context) {
        view.changed = changed
    }

    final class Watcher: UIView {
        var changed: (Bool) -> Void = { _ in }
        private var observers: [any NSObjectProtocol] = []

        override func didMoveToWindow() {
            super.didMoveToWindow()
            // Out of its window, which is how it leaves, it stops listening.
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            for (name, isKey) in [(UIWindow.didBecomeKeyNotification, true), (UIWindow.didResignKeyNotification, false)] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.changed(isKey) }
                })
            }
            changed(window.isKeyWindow)
        }
    }
}
