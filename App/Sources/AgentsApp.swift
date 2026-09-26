import AppKit
import SwiftUI

@main
struct AgentsApp: App {
    @State private var model = AppModel()

    /// Light, dark or the Mac's own, from Settings. Applied to the whole app from here,
    /// once at launch and on every change, so no window decides for itself.
    @AppStorage(Appearance.defaultsKey) private var appearance = Appearance.system

    /// One window, so one of each: the menus act on the window they were made with.
    @State private var requests = WindowRequests()
    @State private var frame = SidebarFrame()

    init() {
        // No tabs: the only way left to a second window, and a second window would be a
        // mirror of the first, because what is selected lives on the one model.
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    var body: some Scene {
        // Still a `WindowGroup`, but one window in practice: File ▸ New Window is
        // replaced by New Session (see `AgentsCommands`), and tabbing is off. Not a
        // `Window` scene, because the window state a `WindowGroup` saved restores no
        // window into one, and the app then opens with nothing on screen.
        WindowGroup {
            ContentView()
                .environment(model)
                .environment(requests)
                .environment(frame)
                .onChange(of: appearance, initial: true) { Appearance.apply(appearance) }
        }
        .defaultSize(width: 1_100, height: 720)
        .commands {
            AgentsCommands(model: model, requests: requests, frame: frame)
        }

        // The app's first Settings scene, and what gives it ⌘, and the menu item.
        // A scene rather than a page beside Spending, which Spending itself is not:
        // that one is read-only by construction, and a limit is the one number in
        // this app a person types.
        Settings {
            TabView {
                Tab("Appearance", systemImage: "circle.lefthalf.filled") { AppearanceSettingsView() }
                Tab("Spending", systemImage: "dollarsign.circle") { CostSettingsView() }
                Tab("Devices", systemImage: "iphone") { DevicesPane() }
                Tab("Servers", systemImage: "server.rack") { ServersSettingsView() }
            }
            .paperGround()
            .environment(model)
        }
    }
}
