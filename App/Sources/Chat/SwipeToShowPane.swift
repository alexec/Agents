import AppKit
import SwiftUI

/// Two fingers right to left across the chat, and the sidebar comes in with what was
/// exchanged; left to right, and it goes again.
///
/// The phone's swipe, on a trackpad. AppKit sends it as scroll events, read here as
/// sideways and kept going, not the page wandering while it is scrolled. A code block or table that scrolls sideways itself
/// keeps its own gesture.
///
/// Watched for as long as the chat is on screen, and taken only when they land on it:
/// hover comes and goes with the pointer, and a swipe often starts without it moving.
struct SwipeToShowPane: ViewModifier {
    /// Right to left.
    let show: () -> Void
    /// Left to right.
    let hide: () -> Void

    @State private var sideways: CGFloat = 0
    @State private var isSwiping = false
    /// Decided for this gesture: it is somebody else's, or it has already done its thing.
    /// Spent until a gesture begins under this chat, so one already going when the
    /// chat appeared cannot open the pane (#358).
    @State private var isSpent = true
    @State private var watcher: Any?
    /// The chat's place in its window, to tell its swipes from anybody else's.
    @State private var anchor = SwipeAnchor()

    /// Far enough to mean it.
    private static let commit: CGFloat = 80

    func body(content: Content) -> some View {
        content
            .background(SwipeAnchorView(anchor: anchor))
            .onAppear(perform: watch)
            .onDisappear(perform: stopWatching)
    }

    private func watch() {
        guard watcher == nil else { return }
        watcher = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [anchor] event in
            guard anchor.holds(window: event.windowNumber, at: event.locationInWindow) else { return event }
            let ownScroller = event.phase == .began && Self.scrollsSideways(under: event)
            let taken = MainActor.assumeIsolated {
                take(phase: event.phase, sideways: event.scrollingDeltaX,
                     downwards: event.scrollingDeltaY, overSidewaysScroller: ownScroller)
            }
            return taken ? nil : event
        }
    }

    private func stopWatching() {
        guard let watcher else { return }
        NSEvent.removeMonitor(watcher)
        self.watcher = nil
        isSwiping = false
        isSpent = true
    }

    @MainActor
    private func take(phase: NSEvent.Phase, sideways delta: CGFloat, downwards: CGFloat,
                      overSidewaysScroller: Bool) -> Bool {
        switch phase {
        case .began:
            sideways = 0
            isSwiping = false
            isSpent = overSidewaysScroller
        case .changed:
            guard !isSpent else { return isSwiping }
            if !isSwiping {
                guard abs(delta) > 3, abs(delta) > abs(downwards) * 2 else {
                    // Going up or down first: the page's, for the rest of it.
                    if abs(downwards) > 3 { isSpent = true }
                    return false
                }
                isSwiping = true
            }
            sideways += delta
            if sideways <= -Self.commit {
                isSpent = true
                show()
            } else if sideways >= Self.commit {
                isSpent = true
                hide()
            }
            return true
        case .ended, .cancelled:
            defer { isSwiping = false }
            return isSwiping
        default:
            break
        }
        return false
    }

    /// Whether the gesture starts over something that scrolls sideways by itself.
    private static func scrollsSideways(under event: NSEvent) -> Bool {
        guard let content = event.window?.contentView,
              var view = content.hitTest(content.convert(event.locationInWindow, from: nil))
        else { return false }
        while true {
            if let scroller = view as? NSScrollView, let document = scroller.documentView,
               document.frame.width > scroller.contentView.bounds.width + 1 {
                return true
            }
            guard let parent = view.superview else { return false }
            view = parent
        }
    }
}

/// Where the chat is, kept by an AppKit view laid behind it.
@MainActor
final class SwipeAnchor {
    weak var view: NSView?

    /// Whether the event is over the chat, in the chat's own window.
    ///
    /// The rectangle is not enough: on macOS 26 the sidebar floats over the detail
    /// column, so a swipe on a session row was in it and opened the pane (#2459). What
    /// the window hits there must be in the chat's own column too.
    nonisolated func holds(window number: Int, at location: NSPoint) -> Bool {
        MainActor.assumeIsolated {
            guard let view, let window = view.window, window.windowNumber == number,
                  view.bounds.contains(view.convert(location, from: nil)),
                  let content = window.contentView,
                  let hit = content.hitTest(content.convert(location, from: nil))
            else { return false }
            return Self.sameColumn(hit, as: view)
        }
    }

    /// Whether `hit` is in the same split view column as `anchor`: under the nearest
    /// split view's child that holds the anchor (AppKit's item wrapper, not always one of
    /// its arranged subviews). With no split view, the window is one column.
    static func sameColumn(_ hit: NSView, as anchor: NSView) -> Bool {
        var child = anchor
        while let parent = child.superview {
            if parent is NSSplitView {
                return hit.isDescendant(of: child)
            }
            child = parent
        }
        return true
    }
}

private struct SwipeAnchorView: NSViewRepresentable {
    let anchor: SwipeAnchor

    func makeNSView(context: Context) -> NSView {
        let view = Anchor()
        anchor.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        anchor.view = view
    }

    /// Where the chat is, never what a click lands on: behind the transcript, it was
    /// still hit before the chat's own rows, so no card took a click (#2374).
    final class Anchor: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

extension View {
    /// Two fingers sideways over the chat: in from the right shows, out to the right hides.
    func swipeToShowPane(show: @escaping () -> Void, hide: @escaping () -> Void) -> some View {
        modifier(SwipeToShowPane(show: show, hide: hide))
    }
}

