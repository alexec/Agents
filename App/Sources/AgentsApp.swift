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
            ContentView(requests: requests, frame: frame)
                .environment(model)
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
                Tab("Agents", systemImage: "cpu") { AgentsSettingsView() }
                Tab("Spending", systemImage: "dollarsign.circle") { CostSettingsView() }
                Tab("Devices", systemImage: "iphone") { DevicesPane() }
                Tab("Servers", systemImage: "server.rack") { ServersSettingsView() }
            }
            .paperGround()
            .environment(model)
        }
    }
}
