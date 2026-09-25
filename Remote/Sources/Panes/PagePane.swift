import AgentsKitCore
import SwiftUI

/// The Page pane (034). Filled in by its story; placed now so the layout can be seen first.
struct PagePane: View {
    let agent: Agent

    var body: some View {
        ContentUnavailableView("Page", systemImage: "doc.richtext")
    }
}
