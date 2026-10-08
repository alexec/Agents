import SwiftUI

/// A key that moves the transcript (#378).
enum TranscriptKey {
    case pageUp, pageDown, top, end
}

/// Which way a hand moved the transcript: up it, back through what was said, or down.
enum TranscriptHand {
    case up, down
}

#if os(macOS)
import AppKit

/// What a hand does to the transcript, told as it happens (#378).
///
/// A wheel or trackpad over it says which way it moved. The pane's own geometry cannot:
/// a lazy stack re-measures its height every frame, and the offset moves with it, so a
/// move up with the height unchanged is as often the stack as the reader. And the keys
/// that read the transcript whenever nothing else is taking them: Page
/// Up and Page Down, Space and Shift-Space a pane at a time, Home and ⌘↑ to the top, End
/// to the end (⌘↓ is View ▸ Jump to Latest).
///
/// The transcript never holds the focus — a click on it leaves the focus where it was,
/// usually the sidebar — so the keys are taken from the window as they arrive, before the
/// sidebar's list can read ⌘↑ as a move to the session above. Not while a text field or
/// editor has the focus: the prompt and the search field keep their own keys.
private struct TranscriptInput: ViewModifier {
    let key: (TranscriptKey) -> Void
    let hand: (TranscriptHand) -> Void
    @State private var holder = Holder()

    private final class Holder {
        weak var view: NSView?
        var monitor: Any?
        var key: (TranscriptKey) -> Void = { _ in }
        var hand: (TranscriptHand) -> Void = { _ in }
    }

    func body(content: Content) -> some View {
        holder.key = key
        holder.hand = hand
        return content
            .background(ViewReader { holder.view = $0 })
            .onAppear(perform: install)
            .onDisappear(perform: remove)
    }

    private func install() {
        guard holder.monitor == nil else { return }
        let holder = holder
        holder.monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .scrollWheel]) { event in
            guard let view = holder.view, let window = view.window, event.window === window,
                  window.attachedSheet == nil else { return event }
            if event.type == .scrollWheel {
                // Over the transcript, and only up or down it: the sidebar scrolls too.
                let at = view.convert(event.locationInWindow, from: nil)
                if view.bounds.contains(at), abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX),
                   event.momentumPhase.isEmpty {
                    holder.hand(event.scrollingDeltaY > 0 ? .up : .down)
                }
                return event
            }
            guard let key = Self.key(for: event, responder: window.firstResponder) else { return event }
            holder.key(key)
            return nil
        }
    }

    private func remove() {
        if let monitor = holder.monitor { NSEvent.removeMonitor(monitor) }
        holder.monitor = nil
    }

    private static func key(for event: NSEvent, responder: NSResponder?) -> TranscriptKey? {
        // The field editor and every text view are NSText: the prompt, the search field.
        if responder is NSText { return nil }
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        switch (event.keyCode, modifiers) {
        case (116, []): return .pageUp
        case (121, []): return .pageDown
        case (115, []), (126, [.command]): return .top
        case (119, []): return .end
        case (49, []), (49, [.shift]):
            // A focused control or list reads Space as its own: press, or find a row.
            if responder is NSControl || responder is NSTableView { return nil }
            return modifiers.contains(.shift) ? .pageUp : .pageDown
        default: return nil
        }
    }
}

/// The AppKit view behind a SwiftUI one: where it is, and in which window.
private struct ViewReader: NSViewRepresentable {
    let found: (NSView) -> Void

    func makeNSView(context: Context) -> Reader {
        let view = Reader()
        view.found = found
        return view
    }

    func updateNSView(_ view: Reader, context: Context) { view.found = found }

    final class Reader: NSView {
        var found: (NSView) -> Void = { _ in }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            found(self)
        }
        // Seen, never hit: the transcript's own views take the clicks.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
#endif

extension View {
    /// See `TranscriptInput`. The Mac only: on a touch screen the scroll phase says when a
    /// finger is on the transcript, and its geometry which way it went.
    @ViewBuilder
    func transcriptInput(key: @escaping (TranscriptKey) -> Void,
                         hand: @escaping (TranscriptHand) -> Void) -> some View {
        #if os(macOS)
        modifier(TranscriptInput(key: key, hand: hand))
        #else
        self
        #endif
    }
}
