#if os(macOS)
import AppKit
import SwiftUI

/// A two-finger pinch on the trackpad over a view, as one magnification from where the
/// pinch began: 1 at the start, 1.5 for half as large again (#3980).
///
/// Read from AppKit's magnify events, as `SwipeToShowPane` reads its swipes. A
/// `MagnifyGesture` on the page's scroll view did not see a trackpad pinch, with the
/// `NSScrollView` and the selectable text under it. A pinch that begins over the view
/// is its own until the fingers lift; one that begins elsewhere is never taken.
struct TrackpadPinch: ViewModifier {
    let changed: (Double) -> Void
    let ended: () -> Void

    /// How far this pinch has gone, while it is this view's.
    @State private var magnification: Double?
    @State private var watcher: Any?
    @State private var anchor = SwipeAnchor()

    func body(content: Content) -> some View {
        content
            .background(SwipeAnchorView(anchor: anchor))
            .onAppear(perform: watch)
            .onDisappear(perform: stopWatching)
    }

    private func watch() {
        guard watcher == nil else { return }
        watcher = NSEvent.addLocalMonitorForEvents(matching: .magnify) { [anchor] event in
            let phase = event.phase
            if phase == .began, !anchor.holds(window: event.windowNumber, at: event.locationInWindow) {
                return event
            }
            let delta = Double(event.magnification)
            let taken = MainActor.assumeIsolated { take(phase: phase, delta: delta) }
            return taken ? nil : event
        }
    }

    private func stopWatching() {
        guard let watcher else { return }
        NSEvent.removeMonitor(watcher)
        self.watcher = nil
        if magnification != nil {
            magnification = nil
            ended()
        }
    }

    @MainActor
    private func take(phase: NSEvent.Phase, delta: Double) -> Bool {
        let next: Double
        switch phase {
        case .began:
            next = 1 + delta
        case .changed:
            guard let so = magnification else { return false }
            next = so + delta
        case .ended, .cancelled:
            guard magnification != nil else { return false }
            magnification = nil
            ended()
            return true
        default:
            return false
        }
        magnification = next
        changed(next)
        return true
    }
}

extension View {
    /// A trackpad pinch over this view: `changed` with the magnification since it
    /// began, `ended` when the fingers lift.
    func trackpadPinch(changed: @escaping (Double) -> Void, ended: @escaping () -> Void) -> some View {
        modifier(TrackpadPinch(changed: changed, ended: ended))
    }
}
#endif
