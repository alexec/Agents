import SwiftUI

@main
struct AgentsApp: App {
    @State private var model = AppModel()

    /// Light, dark or the Mac's own, from Settings. Applied to the whole app from here,
    /// once at launch and on every change, so no window decides for itself.
    @AppStorage(Appearance.defaultsKey) private var appearance = Appearance.system

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .onChange(of: appearance, initial: true) { Appearance.apply(appearance) }
        }
        .defaultSize(width: 1_100, height: 720)
        .commands {
            // A menu item rather than a shortcut on the button. The button only
            // exists while you are scrolled away from the end, which is precisely
            // when a keyboard route is no help if it lives on the button.
            CommandGroup(after: .toolbar) {
                Button("Jump to Latest") { model.scrollToEnd() }
                    .keyboardShortcut(.downArrow, modifiers: .command)
                // The keyboard route to what the sidebar's last row does. The row is
                // the way in; this is for the hands that never leave the keys.
                Button("Spending") { model.showsSpending = true }
            }
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
            }
            .paperGround()
            .environment(model)
        }
    }
}
