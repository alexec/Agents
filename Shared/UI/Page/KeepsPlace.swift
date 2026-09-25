import SwiftUI

/// A scrolling list of rows that remembers which row was at the top, and goes back to
/// it when it is drawn again (034 FR-026).
///
/// A phone moves a pane between a column and a screen of its own when it turns, and
/// between agents when the person does; each time, the view is made afresh. The place is
/// kept outside it, in the pane's state, and handed back. The Mac passes nothing and
/// nothing changes there.
struct KeepsPlace: ViewModifier {
    let place: Binding<Int?>?
    @State private var top: Int?

    func body(content: Content) -> some View {
        if let place {
            content
                .scrollPosition(id: $top, anchor: .top)
                .onAppear { if top == nil { top = place.wrappedValue } }
                .onChange(of: top) { _, now in
                    if let now, now != place.wrappedValue { place.wrappedValue = now }
                }
        } else {
            content
        }
    }
}

extension View {
    /// See `KeepsPlace`. The rows must be in a `.scrollTargetLayout()`, identified by
    /// their index.
    func keepsPlace(_ place: Binding<Int?>?) -> some View {
        modifier(KeepsPlace(place: place))
    }
}
