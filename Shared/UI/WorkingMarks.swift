import AgentsKitCore
import QuartzCore
import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// A working session's marks (#2044), in the sidebar rows, the phone's agent cards and at
/// the chat's foot: three dots that fade up in turn, left to right, while it thinks or
/// replies, and a cog that turns while it runs a tool. `SyncedSpinner` stays for plain
/// loading, where nothing thinks.
///
/// As the spinner (#1558, #1653), each is Core Animation layers whose cycle starts where
/// `SpinnerClock` says it is now, so every mark of a kind on a screen is in step, and the
/// render server draws the frames: a sidebar full of working agents does not wake the main
/// thread. Under Reduce Motion they keep going, as a still mark reads as stuck, but slower.
/// The web page draws the same in `SessionRow.tsx` and `app.css`.
struct ThinkingDots: View {
    /// The well's width and height, in points.
    var size: CGFloat
    /// Grey, as the spinner's, except in the sidebar's marks, which are in the accent.
    var color: Color = .secondary

    var body: some View {
        ClockedMark(kind: .dots, color: color)
            .frame(width: size, height: size)
            // One element and no words of its own: the caller says what it means.
            .accessibilityElement()
    }
}

/// The cog for a session that runs a tool (#2044); see `ThinkingDots`.
struct TurningCog: View {
    var size: CGFloat
    var color: Color = .secondary

    var body: some View {
        ClockedMark(kind: .cog, color: color)
            .frame(width: size, height: size)
            .accessibilityElement()
    }
}

/// The two marks' layers. The colour is resolved against the SwiftUI environment, so it
/// follows light and dark and the accent.
private struct ClockedMark {
    var kind: ClockedMarkView.Kind
    var color: Color

    @MainActor func update(_ view: ClockedMarkView, in environment: EnvironmentValues) {
        view.color = color.resolve(in: environment).cgColor
        view.reduceMotion = environment.accessibilityReduceMotion
    }
}

#if os(macOS)
extension ClockedMark: NSViewRepresentable {
    func makeNSView(context: Context) -> ClockedMarkView { ClockedMarkView(kind: kind) }

    func updateNSView(_ view: ClockedMarkView, context: Context) {
        update(view, in: context.environment)
    }
}
#else
extension ClockedMark: UIViewRepresentable {
    func makeUIView(context: Context) -> ClockedMarkView { ClockedMarkView(kind: kind) }

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

/// The layers of one mark, and their cycle kept in step with the clock.
private final class ClockedMarkView: PlatformView {
    enum Kind { case dots, cog }

    private let kind: Kind
    /// The dots, left to right; empty for the cog.
    private var dots: [CALayer] = []
    /// The cog: a layer in the colour, masked by the symbol, turned as one.
    private let cog = CALayer()
    private let cogShape = CALayer()
    private static let cycleKey = "cycle"

    /// AppKit's layers count y up, UIKit's count y down: the turn goes the other way round
    /// on the Mac, so the cog turns clockwise on both.
    #if os(macOS)
    private static let clockwise: CGFloat = -1
    #else
    private static let clockwise: CGFloat = 1
    #endif

    /// How dim a dot is while the others take their turn.
    private static let restingOpacity: Float = 0.3

    var color: CGColor? {
        didSet {
            guard color != oldValue else { return }
            withoutActions {
                for dot in dots { dot.backgroundColor = color }
                cog.backgroundColor = color
            }
        }
    }

    var reduceMotion = false {
        didSet { if reduceMotion != oldValue, window != nil { startCycle() } }
    }

    init(kind: Kind) {
        self.kind = kind
        super.init(frame: .zero)
        #if os(macOS)
        wantsLayer = true
        let host = layer
        #else
        isUserInteractionEnabled = false
        backgroundColor = .clear
        let host: CALayer? = layer
        #endif
        switch kind {
        case .dots:
            dots = (0..<3).map { _ in CALayer() }
            for dot in dots {
                dot.opacity = Self.restingOpacity
                host?.addSublayer(dot)
            }
        case .cog:
            cogShape.contentsGravity = .resizeAspect
            cog.mask = cogShape
            host?.addSublayer(cog)
        }
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

    private var scale: CGFloat = 2

    private func setScale(_ scale: CGFloat) {
        self.scale = scale
        for dot in dots { dot.contentsScale = scale }
        cog.contentsScale = scale
        cogShape.contentsScale = scale
        placeLayers()
    }

    /// Sizes the layers to the view: three dots across the middle of the well, or the cog
    /// filling it.
    private func placeLayers() {
        let side = min(bounds.width, bounds.height)
        guard side > 0 else { return }
        withoutActions {
            switch kind {
            case .dots:
                let diameter = side * 0.24
                let gap = side * 0.1
                let width = 3 * diameter + 2 * gap
                for (index, dot) in dots.enumerated() {
                    dot.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
                    dot.cornerRadius = diameter / 2
                    dot.position = CGPoint(
                        x: bounds.midX - width / 2 + diameter / 2 + CGFloat(index) * (diameter + gap),
                        y: bounds.midY)
                }
            case .cog:
                let frame = CGRect(x: 0, y: 0, width: side, height: side)
                cog.bounds = frame
                cog.position = CGPoint(x: bounds.midX, y: bounds.midY)
                cogShape.frame = frame
                cogShape.contents = Self.cogImage(side: side, scale: scale)
            }
        }
    }

    /// Starts the cycle from where the clock is in it now. The render server runs it;
    /// nothing here runs again until the mark changes window or Reduce Motion changes.
    private func startCycle() {
        let slowing = reduceMotion ? SpinnerClock.reducedMotionSlowing : 1
        let now = Date()
        switch kind {
        case .dots:
            let period = SpinnerClock.dotsPeriod * slowing
            let offset = SpinnerClock.fraction(at: now, period: period) * period
            for (index, dot) in dots.enumerated() {
                // Each dot comes up and goes down in its fifth of the pass, left to right,
                // and the last fifth rests before the row goes again.
                let start = Double(index) * 0.2
                let fade = CAKeyframeAnimation(keyPath: "opacity")
                fade.values = [Self.restingOpacity, Self.restingOpacity, 1, Self.restingOpacity, Self.restingOpacity]
                fade.keyTimes = [0, start, start + 0.2, start + 0.4, 1].map { NSNumber(value: $0) }
                fade.duration = period
                fade.repeatCount = .infinity
                fade.timeOffset = offset
                // Kept when the app goes to the background, so the dots still go on return.
                fade.isRemovedOnCompletion = false
                dot.add(fade, forKey: Self.cycleKey)
            }
        case .cog:
            let period = SpinnerClock.cogPeriod * slowing
            let turn = CABasicAnimation(keyPath: "transform.rotation.z")
            turn.fromValue = 0
            turn.toValue = Self.clockwise * 2 * .pi
            turn.duration = period
            turn.repeatCount = .infinity
            turn.timeOffset = SpinnerClock.fraction(at: now, period: period) * period
            turn.isRemovedOnCompletion = false
            cog.add(turn, forKey: Self.cycleKey)
        }
    }

    /// The `gearshape` symbol as an image the size of the well, for the cog's mask.
    private static func cogImage(side: CGFloat, scale: CGFloat) -> CGImage? {
        #if os(macOS)
        let configuration = NSImage.SymbolConfiguration(pointSize: side * 0.8, weight: .medium)
        guard let symbol = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return nil }
        var rect = CGRect(origin: .zero, size: CGSize(width: side * scale, height: side * scale))
        return symbol.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        #else
        let configuration = UIImage.SymbolConfiguration(pointSize: side * 0.8, weight: .medium)
        guard let symbol = UIImage(systemName: "gearshape", withConfiguration: configuration) else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        let size = CGSize(width: side, height: side)
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            let fit = symbol.size
            symbol.draw(in: CGRect(x: (side - fit.width) / 2, y: (side - fit.height) / 2,
                                   width: fit.width, height: fit.height))
        }.cgImage
        #endif
    }

    private func withoutActions(_ change: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        change()
        CATransaction.commit()
    }
}
