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
            }
        }
    }
}
