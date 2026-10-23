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

/// A waiting session's mark (#2456), in the sidebar rows, the page rows and the phone's agent
/// cards: one dot, the ring's dot, that breathes, a slow fade between dim and full like a
/// sleep light. Asleep, but alive. The app will carry the session on by itself (an event
/// wait, a lease, an allowance, a queued place), so the mark asks for no attention: it is
/// small, slow and in the accent, where the grey unread dot before a title is still, larger
/// and grey. Motion, not a fourth symbol after the hourglass, `moon.zzz` and `zzz` (#765).
///
/// As the ring, it is one Core Animation layer whose breath starts where `SpinnerClock`
/// says it is now, so every waiting dot on a screen breathes in step, and the render server
/// draws it. Under Reduce Motion it breathes slower; a still dot would read as a bullet.
/// The web page draws the same in `SessionRow.tsx` and `spinnerClock.ts`.
struct BreathingDot: View {
    /// The well's width and height, in points.
    var size: CGFloat
    /// The accent, as the sidebar's marks; the ground on a row filled with the accent (#2382).
    var color: Color = Paper.accent

    var body: some View {
        BreathingMark(color: color)
            .frame(width: size, height: size)
            // One element and no words of its own: the caller says what it means.
            .accessibilityElement()
    }

    /// One breath, in seconds: `waitingMarkPeriod` in the defaults (`defaults write` the
    /// app's domain), read once at launch, else 4 (#2456).
    static let period: TimeInterval = {
        let set = WindowDefaults.store.object(forKey: SpinnerClock.breathPeriodKey) as? NSNumber
        return SpinnerClock.breathPeriod(from: set?.doubleValue)
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

/// The dot's layer, its colour resolved as the ring's.
private struct BreathingMark {
    var color: Color

    @MainActor func update(_ view: BreathingDotView, in environment: EnvironmentValues) {
        view.color = color.resolve(in: environment).cgColor
        view.reduceMotion = environment.accessibilityReduceMotion
    }
}

#if os(macOS)
extension ClockedMark: NSViewRepresentable {
    func makeNSView(context: Context) -> ClockedMarkView { ClockedMarkView() }

    func updateNSView(_ view: ClockedMarkView, context: Context) {
        update(view, in: context.environment)
    }
}

extension BreathingMark: NSViewRepresentable {
    func makeNSView(context: Context) -> BreathingDotView { BreathingDotView() }

    func updateNSView(_ view: BreathingDotView, context: Context) {
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

extension BreathingMark: UIViewRepresentable {
    func makeUIView(context: Context) -> BreathingDotView { BreathingDotView() }

    func updateUIView(_ view: BreathingDotView, context: Context) {
        update(view, in: context.environment)
    }
}
#endif

#if os(macOS)
private typealias PlatformView = NSView
#else
private typealias PlatformView = UIView
#endif

/// A mark of dots that Core Animation moves on a cycle kept in step with the clock: the
/// layers, their colour and scale, and when to lay them out and start the cycle again
/// (a window, a size, Reduce Motion). The ring and the breathing dot each say where their
/// dots go and what their cycle is.
private class ClockedLayersView: PlatformView {
    /// The dots, left to right at the start of the cycle.
    let dots: [CALayer]

    /// AppKit's layers count y up, UIKit's count y down: the marks tip the same way on both.
    #if os(macOS)
    static let up: CGFloat = 1
    #else
    static let up: CGFloat = -1
    #endif

    /// Points in one cycle the keyframes go through: 25 ms apart in the ring's at full speed.
    static let samples = 144

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

    init(dots count: Int) {
        dots = (0..<count).map { _ in CALayer() }
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

    /// The well's side, in points.
    var side: CGFloat { min(bounds.width, bounds.height) }

    /// Sizes the dots to the well and puts them where the cycle starts.
    private func placeLayers() {
        guard side > 0, bounds != placed else { return }
        placed = bounds
        withoutActions { place() }
        if window != nil { startCycle() }
    }

    /// Where the dots are at the start of the cycle, and how big, for `bounds`.
    func place() {}

    /// Starts the cycle from where the clock is in it now. The render server runs it;
    /// nothing here runs again until the mark changes window, size, activity or Reduce
    /// Motion.
    func startCycle() {}

    /// A dot's size and corner for a diameter that is `fraction` of the well's side.
    func size(_ dot: CALayer, fraction: Double) {
        let diameter = side * fraction
        dot.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        dot.cornerRadius = diameter / 2
    }

    /// Runs `animation` round and round at `period`, from where the clock is in it now.
    /// Kept when the app goes to the background, so the mark still moves on return.
    func run(_ animation: CAKeyframeAnimation, period: TimeInterval, on dot: CALayer, forKey key: String) {
        animation.duration = period
        animation.repeatCount = .infinity
        animation.timeOffset = SpinnerClock.fraction(at: Date(), period: period) * period
        animation.isRemovedOnCompletion = false
        dot.add(animation, forKey: key)
    }

    func withoutActions(_ change: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        change()
        CATransaction.commit()
    }
}

/// The layers of one ring, and their cycle kept in step with the clock.
private final class ClockedMarkView: ClockedLayersView {
    private static let cycleKeys = ["position", "opacity"]

    /// How far the ring pivots each way, in degrees: 0 while it thinks.
    var tilt: Double = 0 {
        didSet { if tilt != oldValue, window != nil { startCycle() } }
    }

    convenience init() { self.init(dots: 3) }

    /// Today's three dots across the well's middle.
    override func place() {
        for (dot, place) in zip(dots, SpinnerClock.ringDots(at: 0, tilt: 0)) {
            size(dot, fraction: SpinnerClock.ringDotDiameter)
            dot.position = point(place)
            dot.opacity = Float(place.opacity)
        }
    }

    private func point(_ dot: SpinnerClock.RingDot) -> CGPoint {
        CGPoint(x: bounds.midX + dot.x * side, y: bounds.midY + Self.up * dot.y * side)
    }

    override func startCycle() {
        guard side > 0 else { return }
        let period = SpinnerClock.ringPeriod * (reduceMotion ? SpinnerClock.reducedMotionSlowing : 1)
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
                run(animation, period: period, on: dot, forKey: key)
            }
        }
    }
}

/// The one layer of a breathing dot (#2456), and its breath kept in step with the clock.
private final class BreathingDotView: ClockedLayersView {
    convenience init() { self.init(dots: 1) }

    /// The dot at the well's centre, dim: the start of a breath.
    override func place() {
        for dot in dots {
            size(dot, fraction: SpinnerClock.breathDotDiameter)
            dot.position = CGPoint(x: bounds.midX, y: bounds.midY)
            dot.opacity = Float(SpinnerClock.breathOpacity(at: 0))
        }
    }

    override func startCycle() {
        guard side > 0 else { return }
        let breath = BreathingDot.period
        let period = breath * (reduceMotion ? SpinnerClock.reducedMotionSlowing : 1)
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = (0...Self.samples).map {
            Float(SpinnerClock.breathOpacity(at: Double($0) / Double(Self.samples) * breath, period: breath))
        }
        for dot in dots { run(fade, period: period, on: dot, forKey: "opacity") }
    }
}
