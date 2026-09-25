import AppKit
import SwiftUI

/// Two fingers to the right over a chat, and back to the project.
///
/// The same gesture Safari and Finder take as back. AppKit sends it as a scroll event,
/// and the transcript only ever scrolls up and down, so a scroll going sideways over
/// the chat is ours — with one exception: a code block or a diff too wide for the
/// column scrolls sideways too, and one that has been scrolled along is still owed the
/// swipe that brings it back. A gesture that starts over one of those is left to it.
///
/// Watched only while the pointer is over the chat, so the sidebar beside it keeps its
/// own gestures: a web page going back is the browser's business, not this.
struct SwipeBack: ViewModifier {
    /// What the swipe does, once it has gone far enough to mean it.
    let back: () -> Void

    /// How far right the gesture has gone. Never negative.
    @State private var travel: CGFloat = 0
    @State private var isSwiping = false
    /// Set when a gesture began over something that scrolls sideways itself, and kept
    /// until that gesture ends.
    @State private var belongsToContent = false
    @State private var swallowsMomentum = false
    @State private var watcher: Any?

    /// Far enough to mean it.
    private static let commit: CGFloat = 120
    /// How far the page itself follows the fingers: a hint that it is going, not the
    /// page going.
    private static let drift: CGFloat = 0.25

    func body(content: Content) -> some View {
        content
            .offset(x: travel * Self.drift)
            .overlay(alignment: .leading) { arrow }
            .onHover { hovering in
                if hovering { watch() } else { stopWatching() }
            }
            .onDisappear(perform: stopWatching)
    }

    /// Said at the edge the page is going towards, filling in once letting go would
    /// take you back.
    @ViewBuilder
    private var arrow: some View {
        if travel > 0 {
            let committed = travel >= Self.commit
            Image(systemName: "chevron.left")
                .appText(.reading).fontWeight(.semibold)
                .foregroundStyle(committed ? Paper.ground : Color.secondary)
                .frame(width: 36, height: 36)
                .background(committed ? Paper.ink : Paper.raised, in: Circle())
                .overlay(Circle().strokeBorder(Paper.rule, lineWidth: 1))
                .opacity(min(1, travel / Self.commit))
                .offset(x: min(travel, Self.commit) * 0.3 - 24)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private func watch() {
        guard watcher == nil else { return }
        watcher = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            let taken = MainActor.assumeIsolated {
                if event.phase == .began {
                    belongsToContent = Self.startsOverSidewaysScroller(event)
                }
                return take(
                    phase: event.phase,
                    momentum: event.momentumPhase,
                    sideways: event.scrollingDeltaX,
                    downwards: event.scrollingDeltaY
                )
            }
            return taken ? nil : event
        }
    }

    private func stopWatching() {
        guard let watcher else { return }
        NSEvent.removeMonitor(watcher)
        self.watcher = nil
        if travel != 0 { withAnimation(.spring(duration: 0.28)) { travel = 0 } }
        isSwiping = false
        belongsToContent = false
        swallowsMomentum = false
    }

    /// Whether the pointer is over something that is scrolled along sideways and could
    /// come back: that swipe is the content's.
    @MainActor
    private static func startsOverSidewaysScroller(_ event: NSEvent) -> Bool {
        guard let window = event.window,
              let hit = window.contentView?.hitTest(event.locationInWindow) else { return false }
        var view: NSView? = hit
        while let current = view {
            if let scroller = current as? NSScrollView,
               scroller.contentView.bounds.origin.x > 0.5 {
                return true
            }
            view = current.superview
        }
        return false
    }

    @MainActor
    private func take(
        phase: NSEvent.Phase,
        momentum: NSEvent.Phase,
        sideways: CGFloat,
        downwards: CGFloat
    ) -> Bool {
        switch phase {
        case .began:
            isSwiping = false
        case .changed:
            guard !belongsToContent else { return false }
            if !isSwiping {
                // Rightwards, and clearly more sideways than down: a page being read
                // wanders a little, and a swipe keeps going.
                guard sideways > 3, sideways > abs(downwards) * 2 else { return false }
                isSwiping = true
            }
            withAnimation(.interactiveSpring) {
                travel = max(0, min(Self.commit * 1.5, travel + sideways))
            }
            return true
        case .ended, .cancelled:
            guard isSwiping else { return false }
            let farEnough = phase == .ended && travel >= Self.commit
            isSwiping = false
            swallowsMomentum = true
            withAnimation(.spring(duration: 0.28)) { travel = 0 }
            if farEnough { back() }
            return true
        default:
            if swallowsMomentum, momentum != [] {
                if momentum == .ended { swallowsMomentum = false }
                return true
            }
        }
        return false
    }
}

extension View {
    /// Two fingers to the right, and back to where this was opened from.
    func swipeBack(_ back: @escaping () -> Void) -> some View {
        modifier(SwipeBack(back: back))
    }
}
