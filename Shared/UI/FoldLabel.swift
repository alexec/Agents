import SwiftUI

extension View {
    /// A `DisclosureGroup`'s label that folds and unfolds it when clicked, as its chevron
    /// does (#440). On the Mac only the system chevron toggles; iOS already toggles on a
    /// tap of the label, so there this does nothing (a second toggle would undo it).
    ///
    /// `simultaneousGesture` sits alongside the list's own handling, as the project row's
    /// does (#375), so selection and the context menu keep working.
    @ViewBuilder
    func togglesFold(_ isOpen: Binding<Bool>) -> some View {
        #if os(macOS)
        frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded { isOpen.wrappedValue.toggle() })
        #else
        self
        #endif
    }
}
