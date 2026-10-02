import SwiftUI

/// An alert that only its own buttons put away (#101).
///
/// SwiftUI closes an open alert when what it presents goes away, and on the Mac it does
/// that in the middle of a layout pass: the sheet's closing animation runs the run loop
/// inside the update, and a nested update then calls through a null pointer. A model
/// that clears or replaces what an alert shows — a reconnect clearing an error, a second
/// error arriving over the first — crashed the window that way.
///
/// So what is shown is held here, apart from the model. Once open it stays, whatever the
/// model does, until a button closes it; then `dismiss` tells the model, and whatever
/// the model has by then is shown on a later turn, never inside the update that closed
/// the last one. One alert at a time, from one item.
private struct HeldAlert<Item: Identifiable, Actions: View, Message: View>: ViewModifier {
    /// What the model wants shown now. Read live, not kept: a closing alert asks for the
    /// next one after the body that made it has gone.
    let wanted: () -> Item?
    let title: (Item) -> String
    /// The alert has closed on `Item`: by a button, or by Escape, which is its cancel.
    let dismiss: (Item) -> Void
    let actions: (Item) -> Actions
    let message: (Item) -> Message

    @State private var shown: Item?

    func body(content: Content) -> some View {
        content
            .onChange(of: wanted()?.id, initial: true) { showNext() }
            .alert(shown.map(title) ?? "",
                   isPresented: Binding(get: { shown != nil }, set: { isShown in
                       guard !isShown, let was = shown else { return }
                       shown = nil
                       dismiss(was)
                       showNext()
                   }),
                   presenting: shown, actions: actions, message: message)
    }

    private func showNext() {
        guard shown == nil else { return }
        Task { @MainActor in
            guard shown == nil, let next = wanted() else { return }
            shown = next
        }
    }
}

extension View {
    /// An alert shown from `item` that the model can neither close nor swap while it is
    /// open (#101). See `HeldAlert`.
    func heldAlert<Item: Identifiable, Actions: View, Message: View>(
        _ title: @escaping (Item) -> String,
        item: @escaping () -> Item?,
        dismiss: @escaping (Item) -> Void,
        @ViewBuilder actions: @escaping (Item) -> Actions,
        @ViewBuilder message: @escaping (Item) -> Message
    ) -> some View {
        modifier(HeldAlert(wanted: item, title: title, dismiss: dismiss, actions: actions, message: message))
    }
}

/// Words an alert holds, as an item to present (#101). Two the same in a row are one.
struct AlertWords: Identifiable, Equatable {
    let text: String
    var id: String { text }
}
