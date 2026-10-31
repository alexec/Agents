import AgentsKitCore
import AppKit
import SwiftUI

@main
struct AgentsApp: App {
    @State private var model = AppModel()
    /// The Dock's menu of folders (#1089).
    @NSApplicationDelegateAdaptor(AgentsAppDelegate.self) private var delegate

    /// Light, dark or the Mac's own, from Settings. Applied to the whole app from here,
    /// once at launch and on every change, so no window decides for itself.
    @AppStorage(Appearance.defaultsKey, store: WindowDefaults.store) private var appearance = Appearance.system

    /// One window, so one of each: the menus act on the window they were made with.
    @State private var requests = WindowRequests()
    @State private var frame = SidebarFrame()
    @State private var terminal = FolderTerminalFrame()

    init() {
        // Before anything can throw: the next layout crash names its view (#76).
        CrashHook.install()
        // And the next hang names its stack (#237).
        HangReporter.install()
        // The defaults of scratch copies that have gone (#1029).
        Task.detached(priority: .utility) { WindowDefaults.sweep() }
        #if DEBUG
        // A scratch copy's walk socket (#1172), for run-app's walk.py; only with --walk.
        WalkServer.startIfWalking()
        #endif
    }

    var body: some Scene {
        // Still a `WindowGroup`, but one window in practice: File ▸ New Window is
        // replaced by New Session (see `AgentsCommands`), and tabbing is off. Not a
        // `Window` scene: the window saved by this group would restore into nothing.
        // Its id is what Window ▸ Agents (All Folders) opens it again by once closed
        // (#1454), and what the saved window is named after. Renaming the id renames
        // the saved window: the one saved last time matches no scene, and the app
        // opens with none.
        WindowGroup(id: MainWindow.sceneID) {
            ContentView(requests: requests, frame: frame, terminal: terminal)
                .environment(model)
                .onChange(of: appearance, initial: true) { Appearance.apply(appearance) }
        }
        .defaultSize(width: 1_100, height: 720)
        .commands {
            AgentsCommands(model: model, requests: requests, frame: frame, terminal: terminal)
        }

        // A session in a window of its own (#826), from Session ▸ Open in New Window or a
        // row's menu. One window per session: opening one already open brings it forward.
        WindowGroup(id: MainWindow.poppedSceneID, for: UUID.self) { $id in
            PoppedChatWindow(id: id)
                .environment(model)
        }
        .defaultSize(width: 640, height: 720)

        // A folder in a window of its own (#1089), from Open in New Window on its heading,
        // ⌥⌘O, a double-click on the heading, the Window menu or the Dock. One per folder:
        // opening one already open brings it forward. Saved and opened again at launch.
        WindowGroup(id: FolderWindowScene.id, for: FolderKey.self) { $key in
            FolderWindow(key: key)
                .environment(model)
        }
        .defaultSize(width: 1_240, height: 760)

        // An artifact in a window of its own (#3034), from Exchanged's "Open in New Window"
        // context-menu item. One window per artifact: opening one already open brings it
        // forward.
        WindowGroup(id: ArtifactWindowScene.id, for: ArtifactWindowKey.self) { $key in
            ArtifactWindow(key: key)
                .environment(model)
        }
        .defaultSize(width: 720, height: 560)

        // The app's first Settings scene, and what gives it ⌘, and the menu item.
        // A scene rather than a page beside Spending, which Spending itself is not:
        // that one is read-only by construction, and a limit is the one number in
        // this app a person types.
        // Opens at one size for every pane. The view's minimum is that size, so
        // the window can be dragged larger and not smaller. The grow box itself
        // is added in `SettingsGrowBox`: this scene does not put one on.
        Settings {
            SettingsWindow()
                .paperGround()
                .environment(model)
        }
        .defaultSize(width: SettingsWindow.size.width, height: SettingsWindow.size.height)
        .windowResizability(.contentMinSize)
    }
}
