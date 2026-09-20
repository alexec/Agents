import SwiftUI

@main
struct AgentsApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
        }
        .defaultSize(width: 1_100, height: 720)
        .commands {
            // A menu item rather than a shortcut on the button. The button only
            // exists while you are scrolled away from the end, which is precisely
            // when a keyboard route is no help if it lives on the button.
            CommandGroup(after: .toolbar) {
                Button("Jump to Latest") { model.scrollToEnd() }
                    .keyboardShortcut(.downArrow, modifiers: .command)
                SpendingMenuItem()
            }
        }

        // A scene of its own, sharing the one `AppModel` the app holds. That sharing
        // is what makes its figures move in step with the main window without a fetch
        // of its own, and a separate window is what makes closing it return you to
        // exactly what you were looking at.
        Window("Spending", id: "spending") {
            SpendingView()
                .environment(model)
        }
        .defaultSize(width: 460, height: 560)

        // The app's first Settings scene, and what gives it ⌘, and the menu item.
        // Separate from the Spending window beside it because that one is read-only
        // by construction, and a limit is the one number in this app a person types.
        Settings {
            CostSettingsView()
                .environment(model)
        }
    }
}

/// The menu route into Spending. Its own view because `openWindow` is an environment
/// value, and a `Scene`'s `commands` builder is not a view that has one.
private struct SpendingMenuItem: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Spending") { openWindow(id: "spending") }
    }
}
