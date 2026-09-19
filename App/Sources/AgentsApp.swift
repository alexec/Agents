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
    }
}
