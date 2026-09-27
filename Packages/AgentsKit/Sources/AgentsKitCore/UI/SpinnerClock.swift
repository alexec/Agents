import Foundation

/// Where every working spinner is in its turn, read off the wall clock.
///
/// The system spinner starts turning when it appears, so a list of working agents
/// showed a dozen spinners each at its own point in the turn, and one that appeared
/// later never caught up. Reading the step from the clock rather than from when the
/// view appeared puts every spinner on a screen at the same spoke on the same frame:
/// the sidebar rows, the chat's working line and the phone's cards turn as one, and a
/// row that appears late joins in step.
///
/// Here rather than in `Shared/UI` so the arithmetic is under test; the view that
/// draws it is `SyncedSpinner`.
public enum SpinnerClock {
    /// One full turn, in seconds. The system spinner's own pace, near enough.
    public static let period: TimeInterval = 1

    /// The instant every spinner counts from. Fixed, so two views that never met
    /// still agree.
    public static let epoch = Date(timeIntervalSinceReferenceDate: 0)

    /// How long one spoke is lit before the next: the spinner ticks, it does not glide.
    public static func tick(spokes: Int) -> TimeInterval {
        period / Double(spokes)
    }

    /// Which spoke is lit at `date`, from 0 to `spokes - 1`, clockwise from the top.
    public static func step(at date: Date, spokes: Int) -> Int {
        let ticks = (date.timeIntervalSince(epoch) / tick(spokes: spokes)).rounded(.down)
        let step = Int(ticks.truncatingRemainder(dividingBy: Double(spokes)))
        // A date before the epoch counts backwards; keep it in range all the same.
        return step < 0 ? step + spokes : step
    }

    /// How strongly `spoke` is drawn while `step` is lit: fully for the lit one,
    /// fading behind it, so the tail trails the way the system spinner's does.
    public static func opacity(ofSpoke spoke: Int, step: Int, spokes: Int) -> Double {
        let behind = ((step - spoke) % spokes + spokes) % spokes
        return 1 - Double(behind) / Double(spokes) * (1 - faintest)
    }

    /// The last spoke of the tail. Never nothing, so the wheel's outline stays.
    public static let faintest = 0.2
}
