import SwiftUI

/// A dictate button that also sends when held and released (#2521).
struct PushToTalkButton<Label: View>: View {
    let tap: () -> Void
    let begin: () -> Void
    let end: () -> Void
    @ViewBuilder let label: () -> Label

    @State private var didHold = false

    var body: some View {
        Button {
            guard !didHold else { return }
            tap()
        } label: {
            label()
        }
        .onLongPressGesture(minimumDuration: 0.4, maximumDistance: 50, pressing: { pressing in
            if pressing {
                didHold = false
            } else if didHold {
                end()
            }
        }, perform: {
            didHold = true
            begin()
        })
        .accessibilityHint("Hold to dictate and send when released. Tap to dictate.")
    }
}
