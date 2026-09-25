import AgentsKitCore
import SwiftUI

/// The Terminal pane (034). Filled in by its story; placed now so the layout can be seen first.
struct TerminalPane: View {
    let agent: Agent

    var body: some View {
        ContentUnavailableView("Terminal", systemImage: "terminal")
    }
}
