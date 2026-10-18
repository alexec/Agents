import Foundation

/// How large a Markdown page's text is drawn (#1419): one level for every page on a
/// device, not one per file, kept in the window's defaults.
///
/// The steps are the ones a browser and Preview use, from 75 % to 200 %. A level read
/// from the defaults that is not a step (an older build, a hand edit) snaps to the
/// nearest, so the next ⌘+ goes one step and not a strange distance.
public enum PageZoom {
    public static let steps: [Double] = [0.75, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2]
    public static let actualSize = 1.0
    /// The defaults key for the level, the same name on the Mac and the Remote.
    public static let defaultsKey = "pageTextZoom"

    /// The step nearest to a level.
    public static func snapped(_ level: Double) -> Double {
        guard level.isFinite else { return actualSize }
        return steps.min { abs($0 - level) < abs($1 - level) } ?? actualSize
    }

    /// One step larger, or the largest step.
    public static func larger(than level: Double) -> Double {
        let current = snapped(level)
        return steps.first { $0 > current } ?? steps[steps.count - 1]
    }

    /// One step smaller, or the smallest step.
    public static func smaller(than level: Double) -> Double {
        let current = snapped(level)
        return steps.last { $0 < current } ?? steps[0]
    }

    public static func canZoomIn(_ level: Double) -> Bool { snapped(level) < steps[steps.count - 1] }
    public static func canZoomOut(_ level: Double) -> Bool { snapped(level) > steps[0] }

    /// The level a pinch has reached: the level it started at, times how far the
    /// fingers moved, on the nearest step. Steps rather than a free scale, so the text
    /// is laid out again only when the step changes, and the menu's steps and a
    /// pinch's are the same.
    public static func pinched(from start: Double, by magnification: Double) -> Double {
        snapped(start * magnification)
    }
}
