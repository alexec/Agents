import SwiftUI

/// A swipe action that moves its own row: Archive and Bring Back (#74).
///
/// AppKit runs the swipe's closing animation on the row view after the button is
/// pressed, and lays its buttons out once more when that animation ends. If the row has
/// left the list by then (archived into the fold, or brought back out of it), the table
/// throws from `_updateActionButtonPositionsForRowView:` and the window aborts. So the
/// action waits until the swipe has closed, and the row stays where it is until then.
struct SwipeAction<Label: View>: View {
    let action: @MainActor () async -> Void
    let label: Label

    /// Longer than the table's own closing animation, short enough to read as the press.
    static var settle: Duration { .milliseconds(450) }

    init(action: @escaping @MainActor () async -> Void, @ViewBuilder label: () -> Label) {
        self.action = action
        self.label = label()
    }

    var body: some View {
        Button {
            Task { @MainActor in
                try? await Task.sleep(for: Self.settle)
                await action()
            }
        } label: {
            label
        }
    }
}

extension SwipeAction where Label == Text {
    init(_ title: LocalizedStringKey, action: @escaping @MainActor () async -> Void) {
        self.init(action: action) { Text(title) }
    }
}

extension SwipeAction where Label == SwiftUI.Label<Text, Image> {
    init(_ title: LocalizedStringKey, systemImage: String, action: @escaping @MainActor () async -> Void) {
        self.init(action: action) { SwiftUI.Label(title, systemImage: systemImage) }
    }
}
