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
/// Here rather than in `Shared/UI` so the arithmetic is under test; the view that
/// draws it is `SyncedSpinner`.
public enum SpinnerClock {
    /// One full turn, in seconds. The system spinner's own pace, near enough.
    public static let period: TimeInterval = 1

    /// The instant every spinner counts from. Fixed, so two views that never met
    /// still agree.
    public static let epoch = Date(timeIntervalSinceReferenceDate: 0)

    /// How far the notch has turned at `date`, in degrees from 0 up to 360, clockwise.
    public static func angle(at date: Date) -> Double {
        let turns = date.timeIntervalSince(epoch) / period
        let fraction = turns - turns.rounded(.down)
        // `rounded(.down)` keeps a date before the epoch in range too; the guard is for
        // a fraction that rounds up to a whole turn.
        let degrees = fraction * 360
        return degrees < 360 ? degrees : 0
    }
}
