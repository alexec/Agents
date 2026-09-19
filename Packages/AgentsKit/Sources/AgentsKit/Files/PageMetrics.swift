import Foundation

/// The reading surface, as arithmetic.
///
/// A document is read at a line length, not at whatever width the pane happens to be.
/// This turns one into the other, and it lives here rather than in the view for two
/// reasons: the numbers came out of a measurement and will rot silently unless a test
/// holds them, and two renderers have to agree on them. The SwiftUI page and the
/// stylesheet a rendered HTML file is given both read from this, so "the same reading
/// surface" (FR-004) is a shared function rather than two sets of numbers someone has
/// to remember to keep level.
///
/// Measured on this Mac with real prose rather than with the average-character myth:
/// the document face averages 5.56 points per character, so 340 points of text is 61
/// characters and 500 points is 90. Those are the two ends SC-003 asks for.
public struct PageMetrics: Hashable, Sendable {
    /// The widest the text may run, in points. Beyond this the surface centres itself
    /// and lets the pane be wide.
    public let measure: Double
    /// Horizontal padding, each side.
    public let padding: Double

    public init(measure: Double, padding: Double) {
        self.measure = measure
        self.padding = padding
    }

    /// Ninety characters at the document face. Past this a line is a thing you lose
    /// your place in on the way back to the left.
    public static let measureCap: Double = 500

    /// What the padding is when there is room for it, and what it falls to when there
    /// is not. FR-005 says the padding gives way as the pane narrows, not the text:
    /// 46 characters of readable prose beats 61 characters that do not fit.
    public static let widePadding: Double = 20
    public static let tightPadding: Double = 12

    /// The pane's own limits, mirrored. `SidebarFrame` owns them, and it is in the app
    /// target where this cannot see it; they are repeated rather than shared because
    /// the alternative is the kit depending on the window.
    static let narrowPane: Double = 280
    static let comfortablePane: Double = 380

    /// The surface for a pane of this width.
    ///
    /// The padding ramps between the two widths rather than stepping at a threshold.
    /// A step would make the measure jump *outwards* as the pane got narrower — cross
    /// the boundary going down and the text suddenly has more room — which reads as a
    /// glitch while somebody is dragging the resize handle. Ramping keeps `measure`
    /// monotonic in `width`, which is the property that keeps the page still.
    public static func forPane(width: Double) -> PageMetrics {
        let padding: Double
        if width <= narrowPane {
            padding = tightPadding
        } else if width >= comfortablePane {
            padding = widePadding
        } else {
            let t = (width - narrowPane) / (comfortablePane - narrowPane)
            padding = tightPadding + t * (widePadding - tightPadding)
        }
        let available = max(0, width - padding * 2)
        return PageMetrics(measure: min(measureCap, available), padding: padding)
    }
}
