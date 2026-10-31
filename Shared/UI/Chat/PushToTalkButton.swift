import AgentsKitCore
import SwiftUI

/// A dictate button that also sends when held and released (#2521). Dragged away and let
/// go, it cancels instead of sending, as in Messages (#2753).
struct PushToTalkButton<Label: View>: View {
    let tap: () -> Void
    let begin: () -> Void
    let end: () -> Void
    let cancel: () -> Void
    @ViewBuilder let label: () -> Label

    @State private var press = PushToTalkPress()
    @State private var isPressing = false
    /// A held press ends with the drag, not the button: the tap that follows is not one.
    @State private var didHold = false
    @State private var hold: Task<Void, Never>?

    var body: some View {
        Button {
            guard !didHold else {
                didHold = false
                return
            }
            tap()
        } label: {
            label()
                // Letting go here cancels.
                .opacity(press.isHeld && press.isDraggedOff ? 0.4 : 1)
        }
        .simultaneousGesture(DragGesture(minimumDistance: 0)
            .onChanged { drag in
                if !isPressing {
                    isPressing = true
                    didHold = false
                    hold = Task { @MainActor in
                        try? await Task.sleep(for: PushToTalkPress.holdTime)
                        guard !Task.isCancelled, isPressing, press.held() else { return }
                        didHold = true
                        begin()
                    }
                }
                press.moved(by: drag.translation.width, drag.translation.height)
            }
            .onEnded { drag in
                isPressing = false
                hold?.cancel()
                hold = nil
                switch press.ended(at: drag.translation.width, drag.translation.height) {
                case .send: end()
                case .cancel: cancel()
                case nil: break
                }
            })
        .accessibilityHint("Hold to dictate and send when released, or drag away to cancel. Tap to dictate.")
    }
}
