import AgentsKitCore
import Foundation
import QuartzCore
import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// A working session's mark (#2044, #2332), in the sidebar rows, the phone's agent cards and
/// at the chat's foot: three dots on a ring seen edge on. While the session thinks or
/// replies the ring spins about the vertical axis, so the dots slide left and right, bright
/// at the front and dim at the back; while it runs a tool the same ring also pivots about
/// the horizontal axis, so the line opens into a thin ellipse that tips up and down. One
/// view for both, so a change of activity changes the keyframes on the same layers.
/// `SyncedSpinner` stays for plain loading, where nothing thinks.
///
/// As the spinner (#1558, #1653), it is Core Animation layers whose cycle starts where
/// `SpinnerClock` says it is now, so every ring on a screen is in step, and the render
/// server draws the frames: a sidebar full of working agents does not wake the main
/// thread. Under Reduce Motion it keeps going, as a still mark reads as stuck, but slower.
/// The web page draws the same in `SessionRow.tsx` and `spinnerClock.ts`.
struct WorkingRing: View {
    /// The well's width and height, in points.
    var size: CGFloat
    /// Grey, as the spinner's, except in the sidebar's marks, which are in the accent.
    var color: Color = .secondary
    /// True while the session runs a tool: the ring pivots as it spins.
    var doing = false

    var body: some View {
        ClockedMark(tilt: doing ? Self.tilt : 0, color: color)
            .frame(width: size, height: size)
            // One element and no words of its own: the caller says what it means.
            .accessibilityElement()
    }

    /// How far the ring pivots while it runs a tool, in degrees: `workingMarkTilt` in the
    /// defaults (`defaults write` the app's domain), read once at launch, else 30 (#2332).
    static let tilt: Double = {
        let set = WindowDefaults.store.object(forKey: SpinnerClock.ringTiltKey) as? NSNumber
        guard let degrees = set?.doubleValue, degrees.isFinite else { return SpinnerClock.ringTilt }
        return min(max(degrees, 0), 90)
    }()
}

/// The ring's layers. The colour is resolved against the SwiftUI environment, so it
/// follows light and dark and the accent.
private struct ClockedMark {
    var tilt: Double
    var color: Color

    @MainActor func update(_ view: ClockedMarkView, in environment: EnvironmentValues) {
        view.color = color.resolve(in: environment).cgColor
        view.reduceMotion = environment.accessibilityReduceMotion
        view.tilt = tilt
    }
}

#if os(macOS)
extension ClockedMark: NSViewRepresentable {
    func makeNSView(context: Context) -> ClockedMarkView { ClockedMarkView() }

    func updateNSView(_ view: ClockedMarkView, context: Context) {
        update(view, in: context.environment)
    }
}
#else
extension ClockedMark: UIViewRepresentable {
    func makeUIView(context: Context) -> ClockedMarkView { ClockedMarkView() }

    func updateUIView(_ view: ClockedMarkView, context: Context) {
        update(view, in: context.environment)
    }
}
#endif

#if os(macOS)
private typealias PlatformView = NSView
#else
private typealias PlatformView = UIView
#endif

/// The layers of one ring, and their cycle kept in step with the clock.
private final class ClockedMarkView: PlatformView {
    /// The dots, left to right at the start of the cycle.
    private let dots = (0..<3).map { _ in CALayer() }
    private static let cycleKeys = ["position", "opacity"]

    /// AppKit's layers count y up, UIKit's count y down: the ring tips the same way on both.
    #if os(macOS)
    private static let up: CGFloat = 1
    #else
    private static let up: CGFloat = -1
    #endif

    /// Points in one cycle the keyframes go through, 25 ms apart at full speed.
    private static let samples = 144

    var color: CGColor? {
        didSet {
            guard color != oldValue else { return }
            withoutActions {
                for dot in dots { dot.backgroundColor = color }
            }
        }
    }

    var reduceMotion = false {
        didSet { if reduceMotion != oldValue, window != nil { startCycle() } }
    }

    /// How far the ring pivots each way, in degrees: 0 while it thinks.
    var tilt: Double = 0 {
        didSet { if tilt != oldValue, window != nil { startCycle() } }
    }

    init() {
        super.init(frame: .zero)
        #if os(macOS)
        wantsLayer = true
        let host = layer
        #else
        isUserInteractionEnabled = false
        backgroundColor = .clear
        let host: CALayer? = layer
        #endif
        for dot in dots { host?.addSublayer(dot) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    #if os(macOS)
    override func layout() {
        super.layout()
        placeLayers()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        setScale(window.backingScaleFactor)
        startCycle()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if let window { setScale(window.backingScaleFactor) }
    }
    #else
    override func layoutSubviews() {
        super.layoutSubviews()
        placeLayers()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        setScale(traitCollection.displayScale)
        startCycle()
    }
    #endif

    private func setScale(_ scale: CGFloat) {
        for dot in dots { dot.contentsScale = scale }
    }

    /// The well the keyframes were made for: a new size makes them again.
    private var placed = CGRect.null

    /// Sizes the dots to the well and puts them where the cycle starts: today's three dots
    /// across its middle.
    private func placeLayers() {
        guard min(bounds.width, bounds.height) > 0, bounds != placed else { return }
        placed = bounds
        let diameter = min(bounds.width, bounds.height) * SpinnerClock.ringDotDiameter
        withoutActions {
            for (dot, place) in zip(dots, SpinnerClock.ringDots(at: 0, tilt: 0)) {
                dot.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
                dot.cornerRadius = diameter / 2
                dot.position = point(place)
                dot.opacity = Float(place.opacity)
            }
        }
        if window != nil { startCycle() }
    }

    private func point(_ dot: SpinnerClock.RingDot) -> CGPoint {
        let side = min(bounds.width, bounds.height)
        return CGPoint(x: bounds.midX + dot.x * side, y: bounds.midY + Self.up * dot.y * side)
    }

    /// Starts the cycle from where the clock is in it now. The render server runs it;
    /// nothing here runs again until the mark changes window, size, activity or Reduce
    /// Motion.
    private func startCycle() {
        guard min(bounds.width, bounds.height) > 0 else { return }
        let period = SpinnerClock.ringPeriod * (reduceMotion ? SpinnerClock.reducedMotionSlowing : 1)
        let offset = SpinnerClock.fraction(at: Date(), period: period) * period
        let frames = (0...Self.samples).map {
            SpinnerClock.ringDots(at: Double($0) / Double(Self.samples) * SpinnerClock.ringPeriod, tilt: tilt)
        }
        for (index, dot) in dots.enumerated() {
            let move = CAKeyframeAnimation(keyPath: "position")
            #if os(macOS)
            move.values = frames.map { NSValue(point: point($0[index])) }
            #else
            move.values = frames.map { NSValue(cgPoint: point($0[index])) }
            #endif
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = frames.map { Float($0[index].opacity) }
            for (animation, key) in zip([move, fade], Self.cycleKeys) {
                animation.duration = period
                animation.repeatCount = .infinity
                animation.timeOffset = offset
                // Kept when the app goes to the background, so the ring still turns on return.
                animation.isRemovedOnCompletion = false
                dot.add(animation, forKey: key)
            }
        }
    }

    private func withoutActions(_ change: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        change()
        CATransaction.commit()
    }
}
