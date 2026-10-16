import AgentsKitCore
import AppKit
import SwiftUI

@main
struct AgentsApp: App {
    @State private var model = AppModel()
    /// The Dock's menu of projects (#1089).
    @NSApplicationDelegateAdaptor(AgentsAppDelegate.self) private var delegate

    /// Light, dark or the Mac's own, from Settings. Applied to the whole app from here,
    /// once at launch and on every change, so no window decides for itself.
    @AppStorage(Appearance.defaultsKey, store: WindowDefaults.store) private var appearance = Appearance.system

    /// One window, so one of each: the menus act on the window they were made with.
    @State private var requests = WindowRequests()
    @State private var frame = SidebarFrame()
    @State private var terminal = ProjectTerminalFrame()

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
        // `Window` scene, for the same reason as the note below: the window saved by
        // this group would restore into nothing.
        WindowGroup {
            // Exactly `ContentView().environment(model).onChange(…)` and nothing more.
            // SwiftUI names the saved window after this whole type, modifiers and all,
            // so one more modifier here renames it: the window saved last time matches
            // no scene, and the app opens with none. What the window needs besides the
            // model goes in through `ContentView`'s own properties instead.
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

        // A project in a window of its own (#1089), from Open in New Window on its heading,
        // ⌥⌘O, a double-click on the heading, the Window menu or the Dock. One per project:
        // opening one already open brings it forward. Saved and opened again at launch.
        WindowGroup(id: ProjectWindowScene.id, for: ProjectKey.self) { $key in
            ProjectWindow(key: key)
                .environment(model)
        }
        .defaultSize(width: 1_240, height: 760)

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
