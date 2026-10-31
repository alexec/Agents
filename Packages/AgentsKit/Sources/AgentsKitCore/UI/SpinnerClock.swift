import Foundation

/// Where every working spinner is in its turn, read off the wall clock.
///
/// The system spinner starts turning when it appears, so a list of working agents
/// showed a dozen spinners each at its own point in the turn, and one that appeared
/// later never caught up. Reading the angle from the clock rather than from when the
/// view appeared puts the notch of every spinner on a screen at the same angle on the
/// same frame: the sidebar rows, the chat's working line and the phone's cards turn as
/// one, and a row that appears late joins in step.
///
/// Here rather than in `Shared/UI` so the arithmetic is under test; the views that
/// draw it are `SyncedSpinner`, `WorkingRing` and `WaitingBeacon`.
public enum SpinnerClock {
    /// One full turn, in seconds. The system spinner's own pace, near enough.
    public static let period: TimeInterval = 1

    /// The instant every spinner counts from. Fixed, so two views that never met
    /// still agree.
    public static let epoch = Date(timeIntervalSinceReferenceDate: 0)

    /// One turn of the working ring (#2332): three dots on a ring seen edge on, which spins
    /// about the vertical axis while the session thinks or replies.
    public static let ringSpinPeriod: TimeInterval = 1.8

    /// One pivot of the ring about the horizontal axis while the session runs a tool
    /// (#2332): up, down and back, once in two turns.
    public static let ringPivotPeriod: TimeInterval = 3.6

    /// The cycle that holds a whole number of turns and pivots: every mark's keyframes run
    /// over it, so a change of activity changes the keyframes and not the cycle.
    public static let ringPeriod: TimeInterval = ringPivotPeriod

    /// How far the ring pivots each way while the session runs a tool, in degrees, unless
    /// `workingMarkTilt` in the defaults (localStorage on the web page) says otherwise.
    public static let ringTilt: Double = 30

    /// The key that changes `ringTilt` without a build (#2332), read once at launch.
    public static let ringTiltKey = "workingMarkTilt"

    /// A dot's diameter and the ring's radius, as fractions of the well's side. At rest
    /// the ring is the three dots of #2044: 0.24 across, 0.34 from centre to centre.
    public static let ringDotDiameter: Double = 0.24
    public static let ringRadius: Double = 0.34 / (3.0.squareRoot() / 2)

    /// How dim a dot is at the back of the ring.
    public static let ringRestingOpacity: Double = 0.3

    /// Under Reduce Motion the marks keep going, as a still one reads as stuck, but this
    /// many times slower.
    public static let reducedMotionSlowing: Double = 2

    /// One breath of the waiting mark (#2456, #2657): the accent beacon fades between dim
    /// and full and back, a slow sine like a sleep light, unless `waitingMarkPeriod` in the
    /// defaults (localStorage on the web page) says otherwise. Asleep, but alive.
    public static let breathPeriod: TimeInterval = 4

    /// The key that changes `breathPeriod` without a build, read once at launch.
    public static let breathPeriodKey = "waitingMarkPeriod"

    /// The shortest and longest breath the key can ask for, in seconds.
    public static let breathPeriodRange: ClosedRange<TimeInterval> = 1...30

    /// How dim the beacon is at the bottom of a breath: the ring's resting opacity.
    public static let breathDimOpacity: Double = ringRestingOpacity

    /// The breath the key asks for: `stored` within `breathPeriodRange`, else `breathPeriod`.
    public static func breathPeriod(from stored: Double?) -> TimeInterval {
        guard let stored, stored.isFinite else { return breathPeriod }
        return min(max(stored, breathPeriodRange.lowerBound), breathPeriodRange.upperBound)
    }

    /// How bright the waiting beacon is `time` seconds into a breath of `period`: dim at the
    /// start, full halfway, dim again at the end, along a cosine so it has no corners.
    public static func breathOpacity(at time: TimeInterval, period: TimeInterval = breathPeriod) -> Double {
        let depth = (1 - cos(2 * .pi * time / period)) / 2
        return breathDimOpacity + (1 - breathDimOpacity) * depth
    }

    /// How far the notch has turned at `date`, in degrees from 0 up to 360, clockwise.
    public static func angle(at date: Date) -> Double {
        fraction(at: date, period: period) * 360
    }

    /// How far into a cycle of `period` seconds every mark is at `date`, from 0 up to 1.
    /// The working ring reads it as the spinner reads its angle, so every ring on a screen
    /// is in step.
    public static func fraction(at date: Date, period: TimeInterval) -> Double {
        let cycles = date.timeIntervalSince(epoch) / period
        let fraction = cycles - cycles.rounded(.down)
        // `rounded(.down)` keeps a date before the epoch in range too; the guard is for
        // a fraction that rounds up to a whole cycle.
        return fraction < 1 ? fraction : 0
    }

    /// Where one dot of the working ring is, in fractions of the well's side from its
    /// centre (y up), and how bright it is.
    public struct RingDot: Equatable, Sendable {
        public var x: Double
        public var y: Double
        public var opacity: Double
    }

    /// The dot at angle `spin` on a ring tipped `tilt` from edge on, both in radians: a
    /// spin of 90° is the front of the ring, at full brightness.
    public static func ringDot(spin: Double, tilt: Double) -> RingDot {
        let depth = (sin(spin) * cos(tilt) + 1) / 2
        return RingDot(x: ringRadius * cos(spin),
                       y: ringRadius * sin(spin) * sin(tilt),
                       opacity: ringRestingOpacity + (1 - ringRestingOpacity) * depth)
    }

    /// The three dots `time` seconds into the cycle, left to right at its start. The ring
    /// turns so that the front dots go left to right; `tilt` is how far it pivots each
    /// way, in degrees: 0 while it thinks, `ringTilt` while it runs a tool.
    public static func ringDots(at time: TimeInterval, tilt: Double) -> [RingDot] {
        let pivot = tilt * .pi / 180 * cos(2 * .pi * time / ringPivotPeriod)
        let turned = 2 * .pi * time / ringSpinPeriod
        // The middle dot starts at the front and the outer two behind it, a third of a turn
        // each way: seen edge on, today's three dots in a line.
        return [7.0 / 6, 1.0 / 2, 11.0 / 6].map { start in
            ringDot(spin: start * .pi - turned, tilt: pivot)
        }
    }
}
