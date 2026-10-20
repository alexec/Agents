import AgentsKitCore
import QuartzCore
import SwiftUI

/// The working spinner, drawn by us so every one on a screen turns in step.
///
/// The system's `ProgressView()` starts its turn when it appears, and nothing can set
/// its phase, so a column of working agents spun out of step with each other and with
/// the chat's working line. This draws a circle-notch, an open ring with round caps
/// (#1606), turned to the angle read off the clock (`SpinnerClock`), so all of them
/// show the notch at the same angle on the same frame.
///
/// The ring is a shape layer that Core Animation turns (#1653): the render server draws
/// each frame, so a sidebar full of working agents does not wake the main thread. A
/// SwiftUI timeline here woke it thirty times a second for each spinner on screen. The
/// turn starts at the clock's angle each time the ring goes into a window, so a ring
/// that appears late joins in step. Like the system spinner it keeps turning under
/// Reduce Motion: a still ring would read as stuck.
struct SyncedSpinner: View {
    /// The ring's width and height, in points.
    var diameter: CGFloat
    /// The ring's colour: grey, as the system's, except in the sidebar's marks, which are
    /// in the accent as the rest of them (#1558).
    var color: Color = .secondary

    var body: some View {
        SpinnerRing(color: color)
            .frame(width: diameter, height: diameter)
            // One element and no words of its own: the caller says what it means, and a
            // label stacked over a child's label overflows AppKit's stack.
            .accessibilityElement()
    }
}

/// The ring and its turn, as Core Animation layers. The colour is resolved against the
/// SwiftUI environment, so it follows light and dark and the accent.
private struct SpinnerRing {
    var color: Color

    @MainActor func update(_ view: SpinnerRingView, in environment: EnvironmentValues) {
        view.strokeColor = color.resolve(in: environment).cgColor
    }
}

#if os(macOS)
extension SpinnerRing: NSViewRepresentable {
    func makeNSView(context: Context) -> SpinnerRingView { SpinnerRingView() }

    func updateNSView(_ view: SpinnerRingView, context: Context) {
        update(view, in: context.environment)
    }
}
#else
extension SpinnerRing: UIViewRepresentable {
    func makeUIView(context: Context) -> SpinnerRingView { SpinnerRingView() }

    func updateUIView(_ view: SpinnerRingView, context: Context) {
        update(view, in: context.environment)
    }
}
#endif

#if os(macOS)
private typealias PlatformView = NSView
#else
private typealias PlatformView = UIView
#endif

/// A view that holds the ring's shape layer and keeps its turn in step with the clock.
private final class SpinnerRingView: PlatformView {
    private let ring = CAShapeLayer()
    private static let turnKey = "turn"

    /// AppKit's layers count y up, UIKit's count y down. The arc and the turn go the
    /// other way round on the Mac, so the notch turns clockwise on both.
    #if os(macOS)
    private static let clockwise: CGFloat = -1
    #else
    private static let clockwise: CGFloat = 1
    #endif

    var strokeColor: CGColor? {
        didSet {
            guard strokeColor != oldValue else { return }
            withoutActions { ring.strokeColor = strokeColor }
        }
    }

    init() {
        super.init(frame: .zero)
        #if os(macOS)
        wantsLayer = true
        layer?.addSublayer(ring)
        #else
        isUserInteractionEnabled = false
        backgroundColor = .clear
        layer.addSublayer(ring)
        #endif
        ring.fillColor = nil
        ring.lineCap = .round
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    #if os(macOS)
    override func layout() {
        super.layout()
        placeRing()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        ring.contentsScale = window.backingScaleFactor
        startTurn()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if let window { ring.contentsScale = window.backingScaleFactor }
    }
    #else
    override func layoutSubviews() {
        super.layoutSubviews()
        placeRing()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        ring.contentsScale = traitCollection.displayScale
        startTurn()
    }
    #endif

    /// Sizes the ring to the view: a circle inset by half the stroke, so the ring and
    /// its caps stay in the frame, with a fifth of it open.
    private func placeRing() {
        let side = min(bounds.width, bounds.height)
        guard side > 0 else { return }
        let lineWidth = side * 0.12
        let radius = (side - lineWidth) / 2
        let path = CGMutablePath()
        // From three o'clock, four fifths of a turn clockwise on the screen, as SwiftUI's
        // `Circle().trim(from: 0, to: 0.8)`.
        path.addArc(
            center: CGPoint(x: side / 2, y: side / 2), radius: radius,
            startAngle: 0, endAngle: Self.clockwise * 0.8 * 2 * .pi,
            clockwise: Self.clockwise < 0)
        withoutActions {
            ring.bounds = CGRect(x: 0, y: 0, width: side, height: side)
            ring.position = CGPoint(x: bounds.midX, y: bounds.midY)
            ring.lineWidth = lineWidth
            ring.path = path
        }
    }

    /// Starts the ring turning from the angle the clock gives now. The render server
    /// runs the turn; nothing here runs again until the ring changes window.
    private func startTurn() {
        let turn = CABasicAnimation(keyPath: "transform.rotation.z")
        turn.fromValue = 0
        turn.toValue = Self.clockwise * 2 * .pi
        turn.duration = SpinnerClock.period
        turn.repeatCount = .infinity
        // Where the clock is in its turn now: every ring started this way agrees.
        turn.timeOffset = SpinnerClock.angle(at: Date()) / 360 * SpinnerClock.period
        // Kept when the app goes to the background, so the ring still turns on return.
        turn.isRemovedOnCompletion = false
        ring.add(turn, forKey: Self.turnKey)
    }

    private func withoutActions(_ change: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        change()
        CATransaction.commit()
    }
}
