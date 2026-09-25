import AppKit
import SwiftUI

/// Push a card to the left with two fingers and its Archive button is uncovered.
///
/// A `List` gets this from `swipeActions`. These are glass cards in a stack, so the
/// gesture is ours to read. AppKit sends a two-finger swipe as a scroll event, and a
/// scroll event going sideways over a card is never anything else: the page under it
/// only goes up and down, and wanted none of them.
///
/// The swipe uncovers the button rather than archiving by itself, the way a row does
/// in Mail: a gesture that ends in the chat being gone is too easy to make by accident
/// while scrolling past it. Pushing the card back, or moving the pointer off it, puts
/// the button away again.
///
/// The events are watched only while the pointer is over the card, so there is one
/// watcher at a time however many cards are on the page.
struct SwipeToArchive: ViewModifier {
    /// What the button does.
    let archive: () async -> Void

    /// How far left the card has been pushed. Never positive: there is nothing on the
    /// other side to reveal.
    @State private var offset: CGFloat = 0
    /// Set once a gesture has gone sideways enough to be a swipe rather than the page
    /// being scrolled, and kept for the rest of that gesture.
    @State private var isSwiping = false
    /// The coast a trackpad sends after the fingers have gone. It belongs to the swipe
    /// that has just finished, not to the page.
    @State private var swallowsMomentum = false
    @State private var watcher: Any?

    /// Where the card rests with the button showing: the button's width and a margin.
    private static let open: CGFloat = 112
    /// Far enough to mean it. Less than that and the card goes back.
    private static let commit: CGFloat = 48
    /// As far as a card goes while a finger is still on it, so the gesture keeps some
    /// weight past the point where it is already decided.
    private static let limit: CGFloat = 148

    func body(content: Content) -> some View {
        ZStack(alignment: .trailing) {
            reveal
            content.offset(x: offset)
        }
        .onHover { hovering in
            if hovering { watch() } else { stopWatching() }
        }
        .onDisappear(perform: stopWatching)
        .accessibilityAction(named: "Archive") { Task { await archive() } }
    }

    /// What is behind the card, uncovered as it moves: the one thing to do with it.
    @ViewBuilder
    private var reveal: some View {
        if offset < 0 {
            Button {
                close()
                Task { await archive() }
            } label: {
                Label("Archive", systemImage: "archivebox")
            }
            .buttonStyle(.paper)
            .appText(.fine)
            .opacity(min(1, -offset / Self.commit))
            .frame(width: Self.open - 12)
            .padding(.trailing, 6)
            .help("Archive this")
            .accessibilityHidden(true)
        }
    }

    private func close() {
        withAnimation(.spring(duration: 0.28)) { offset = 0 }
    }

    private func watch() {
        guard watcher == nil else { return }
        watcher = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            // What the gesture is, read off the event here, so nothing but numbers
            // crosses into the main actor below.
            let taken = MainActor.assumeIsolated {
                take(
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
        if offset != 0 { close() }
        isSwiping = false
        swallowsMomentum = false
    }

    /// Take the sideways gesture and leave everything else alone, so the page still
    /// scrolls under a card being read. Answers whether the event was ours.
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
            if !isSwiping {
                // A page being scrolled wanders sideways a little; a swipe goes
                // sideways and keeps going.
                guard abs(sideways) > 3, abs(sideways) > abs(downwards) * 2 else { return false }
                isSwiping = true
            }
            withAnimation(.interactiveSpring) {
                offset = min(0, max(-Self.limit, offset + sideways))
            }
            return true
        case .ended, .cancelled:
            guard isSwiping else { return false }
            let farEnough = phase == .ended && offset <= -Self.commit
            isSwiping = false
            swallowsMomentum = true
            withAnimation(.spring(duration: 0.28)) { offset = farEnough ? -Self.open : 0 }
            return true
        default:
            // The coast a trackpad sends after a swipe: the page must not inherit it.
            if swallowsMomentum, momentum != [] {
                if momentum == .ended { swallowsMomentum = false }
                return true
            }
        }
        return false
    }
}

extension View {
    /// Two fingers to the left, and this chat's Archive button shows.
    func swipeToArchive(_ archive: @escaping () async -> Void) -> some View {
        modifier(SwipeToArchive(archive: archive))
    }
}
