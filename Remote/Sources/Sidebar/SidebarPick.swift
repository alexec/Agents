import AgentsKitCore
import SwiftUI

extension EnvironmentValues {
    /// The sidebar row picked in the list around it: `RemoteSidebar`'s `sidebarItem`, or a
    /// folder scene's own pick (#4993).
    @Entry var sidebarPick: SidebarItem?
}

extension View {
    /// The row's tag in the sidebar's selection, drawn as Paper v2 picks a row (#4993): the
    /// selection grey with a 3px accent bar (`PaperSelectionRow`), as the Mac's sidebar
    /// (#4977), in place of the system's accent fill under white text.
    func paperTag(_ item: SidebarItem) -> some View {
        tag(item).modifier(PaperPick(item: item))
    }
}

private struct PaperPick: ViewModifier {
    let item: SidebarItem
    @Environment(\.sidebarPick) private var pick

    func body(content: Content) -> some View {
        content.listRowBackground(Group {
            if pick == item { PaperSelectionRow() } else { Color.clear }
        })
    }
}
