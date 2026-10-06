import AgentsKitCore
import SwiftUI

extension View {
    /// This page shows `parts`: they are read as it appears, if not read on this connection
    /// already, and again after a reconnect while it is on screen (#175). What no page on
    /// screen shows is not read on a reconnect at all.
    func shows(_ parts: Set<CatchUpPart>) -> some View {
        modifier(ShowsParts(parts: parts))
    }
}

private struct ShowsParts: ViewModifier {
    let parts: Set<CatchUpPart>
    @Environment(RemoteModel.self) private var model

    func body(content: Content) -> some View {
        content
            .task { await model.showing(parts) }
            .onDisappear { model.notShowing(parts) }
    }
}
