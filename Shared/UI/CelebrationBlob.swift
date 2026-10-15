import AgentsKitCore
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

extension View {
    /// The Blob's celebrations (#986), in the bottom leading corner: up, one bounce, and
    /// away, with confetti when `celebration` has it. Off with the Settings ▸ Appearance
    /// switch. Held while `held` (a question on screen) or while the person types, and
    /// played after; let go at once when off. Never takes a click or a tap.
    func celebrations(_ celebration: Celebration?, enabled: Bool, held: Bool,
                      celebrated: @escaping (Celebration) -> Void) -> some View {
        modifier(Celebrations(celebration: celebration, enabled: enabled, held: held, celebrated: celebrated))
    }
}

private struct Celebrations: ViewModifier {
    var celebration: Celebration?
    var enabled: Bool
    var held: Bool
    var celebrated: (Celebration) -> Void

    @State private var playing: Celebration?
    @State private var typing = Typing()
    @State private var keyboardUp = false

    /// How long after the last key the person counts as typing.
    private static let quiet: Duration = .seconds(3)

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottomLeading) {
                if let playing {
                    CelebrationBlob(confetti: playing.confetti) { self.playing = nil }
                        .id(playing.id)
                        .padding(.leading, 20)
                        .padding(.bottom, 12)
                        .allowsHitTesting(false)
                }
            }
            .task(id: Wait(pending: celebration?.id, enabled: enabled, held: held || keyboardUp,
                           playing: playing != nil)) {
                guard let celebration, playing == nil else { return }
                guard enabled else { return celebrated(celebration) }
                guard !held, !keyboardUp else { return }
                // Typing: wait until the keys have been still a moment.
                while let last = typing.last {
                    let since = ContinuousClock.now - last
                    if since >= Self.quiet { break }
                    try? await Task.sleep(for: Self.quiet - since)
                    if Task.isCancelled { return }
                }
                playing = celebration
                celebrated(celebration)
            }
            #if os(macOS)
            .onAppear { typing.watch() }
            .onDisappear { typing.stop() }
            #else
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                keyboardUp = true
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                keyboardUp = false
            }
            #endif
    }

    private struct Wait: Equatable {
        var pending: Int?
        var enabled: Bool
        var held: Bool
        var playing: Bool
    }
}

/// When a key was last pressed in this app, on the Mac. A class, so a keystroke redraws
/// nothing.
@MainActor
private final class Typing {
    var last: ContinuousClock.Instant?
    #if os(macOS)
    private var monitor: Any?

    func watch() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated { self?.last = .now }
            return event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
    #endif
}

/// One celebration: the Blob comes up from the corner, hops once looking up, and goes
/// back down, with a short burst of confetti over it. With Reduce Motion it fades in and
/// out where it stands, with no hop and no confetti.
struct CelebrationBlob: View {
    var confetti: Bool
    var finished: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var up = false
    @State private var hop = false
    @State private var blinking = false
    @State private var burst: Date?

    private static let size = CGSize(width: 60, height: 58)

    var body: some View {
        Blob(look: CGVector(dx: 0.3, dy: hop ? -0.9 : -0.3), blinking: blinking)
            .frame(width: Self.size.width, height: Self.size.height)
            .scaleEffect(x: hop ? 0.94 : 1, y: hop ? 1.06 : 1, anchor: .bottom)
            // Down below the corner, out of sight, until it comes up.
            .offset(y: reduceMotion ? 0 : (up ? (hop ? -22 : 0) : Self.size.height + 80))
            .opacity(reduceMotion ? (up ? 1 : 0) : 1)
            // Behind it, out of its top, and not moving with its hop.
            .background(alignment: .bottom) {
                if let burst {
                    Confetti(start: burst)
                        .frame(width: 220, height: 200)
                        .offset(y: -Self.size.height * 0.6)
                }
            }
            .accessibilityHidden(true)
            .task { await play() }
    }

    private func play() async {
        let total = Celebration.seconds
        if reduceMotion {
            withAnimation(.easeOut(duration: 0.25)) { up = true }
            try? await Task.sleep(for: .seconds(total - 0.5))
            withAnimation(.easeIn(duration: 0.25)) { up = false }
            try? await Task.sleep(for: .seconds(0.25))
            return finished()
        }
        withAnimation(.spring(duration: 0.4, bounce: 0.35)) { up = true }
        try? await Task.sleep(for: .seconds(0.4))
        withAnimation(.spring(duration: 0.3, bounce: 0.5)) { hop = true }
        if confetti { burst = .now }
        try? await Task.sleep(for: .seconds(0.22))
        withAnimation(.spring(duration: 0.35, bounce: 0.55)) { hop = false }
        try? await Task.sleep(for: .seconds(0.7))
        withAnimation(.easeIn(duration: 0.07)) { blinking = true }
        try? await Task.sleep(for: .milliseconds(130))
        withAnimation(.easeOut(duration: 0.1)) { blinking = false }
        try? await Task.sleep(for: .seconds(total - 0.4 - 0.22 - 0.7 - 0.13 - 0.35))
        withAnimation(.easeIn(duration: 0.3)) { up = false }
        try? await Task.sleep(for: .seconds(0.35))
        finished()
    }
}

/// A short burst of paper bits out of the Blob, drawn in one Canvas for as long as it
/// lasts and then not at all.
private struct Confetti: View {
    var start: Date

    private static let lasts: Double = 1.4
    private static let pieces: [Piece] = (0..<26).map { _ in Piece() }
    /// The Blob's own blues and four bright papers, as the web page's: decoration, not a state.
    private static let colours: [Color] = [Blob.outline, Blob.backFill] + [0xFF7BA9, 0xFFD23F, 0x5ED6B0, 0xFF9F45].map {
        Color(red: Double($0 >> 16 & 0xFF) / 255, green: Double($0 >> 8 & 0xFF) / 255, blue: Double($0 & 0xFF) / 255)
    }

    var body: some View {
        TimelineView(.animation(paused: false)) { timeline in
            let t = timeline.date.timeIntervalSince(start)
            Canvas { context, size in
                guard t < Self.lasts else { return }
                let origin = CGPoint(x: size.width / 2, y: size.height)
                let fade = min(1, (Self.lasts - t) / 0.4)
                for piece in Self.pieces {
                    let x = origin.x + piece.vx * t
                    let y = origin.y - piece.vy * t + 0.5 * 420 * t * t
                    var bit = context
                    bit.opacity = fade
                    bit.translateBy(x: x, y: y)
                    bit.rotate(by: .degrees(piece.spin * t))
                    bit.fill(Path(CGRect(x: -3, y: -1.5, width: 6, height: 3)),
                             with: .color(Self.colours[piece.colour]))
                }
            }
        }
    }

    private struct Piece {
        var vx = Double.random(in: -110...110)
        var vy = Double.random(in: 200...330)
        var spin = Double.random(in: -540...540)
        var colour = Int.random(in: 0..<6)
    }
}
