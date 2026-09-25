import AgentsKitCore
import SwiftUI

/// The Files pane (034). Filled in by its story; placed now so the layout can be seen first.
struct FilesPane: View {
    let agent: Agent

    var body: some View {
        ContentUnavailableView("Files", systemImage: "folder")
    }
}
