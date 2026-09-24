import Foundation

/// How wide the chat's column of text may get, and how little margin it may keep.
///
/// The transcript and the prompt bar used to inset themselves by a fixed 144 points a
/// side, in two places that had to agree with nothing making them. A gutter that does
/// not know how wide the pane is will eventually be wider than the thing it surrounds,
/// and at the default window with the right sidebar open it was: 288 points of margin
/// around 192 of text. This turns a pane width into a measure and a margin instead,
/// the way `PageMetrics` does for the document pane, and lives here rather than in a
/// view for the same two reasons: the numbers must be held by a test, and every
/// surface in the chat column has to agree on them.
///
/// The two anchors the constants were fixed against, at the default 1,100-point window
/// (`AgentsApp`), with the project list at its ideal 240 (`ContentView`) and the sidebar
/// at its stored default, which was 380 when these were set and is 460 now that the
/// document pane needs the room (`SidebarState`):
///
/// - sidebar open: the chat pane was 480 points and is 400 at the wider sidebar. It
///   must yield far more text than margin. It gets 357 of text inside 22 a side —
///   fewer characters than before, which is what opening a document pane costs.
/// - sidebar shut: the pane is 860 points. The old gutter gave 572 of text there, and
///   that is the look the app has been read at, so the cap is set beside it: 580.
///
/// Those widths are arithmetic on the three stored defaults rather than a ruler held
/// to the screen. The project list is a `NavigationSplitView` column and can be
/// dragged, so the numbers are typical rather than exact; the invariants below hold at
/// every width regardless.
///
/// The cap is a property of text, not of this app: ninety characters is where a line
/// becomes one the eye loses its place on between the end of it and the start of the
/// next. 580 points was ninety at the old body face and is eighty-five at the
/// `reading` step the transcript moved to, so it still sits inside the bound and is
/// left where it is rather than chased upwards — `PageMetrics` had to move because a
/// test holds its floor; this one did not.
public struct ChatMetrics: Hashable, Sendable {
    /// The widest the text may run, in points. Past this the column centres and the
    /// surplus becomes margin either side (FR-017, FR-020).
    public let measure: Double
    /// Horizontal padding, each side.
    public let padding: Double

    public init(measure: Double, padding: Double) {
        self.measure = measure
        self.padding = padding
    }

    /// Eighty-five characters at the reading face, and within a few points of what the
    /// old gutter gave at the default window with the sidebar shut, so the default view
    /// barely changes. Only the narrow and the very wide cases do.
    public static let measureCap: Double = 580

    /// What the padding is when there is room for it, and the floor it falls to when
    /// there is not. FR-018 says the margin gives way before the text does.
    public static let widePadding: Double = 40
    public static let tightPadding: Double = 16

    /// Where the ramp runs. Below the narrow width the padding sits at its floor;
    /// above the comfortable width it sits at its full size. The comfortable width is
    /// the cap plus the full padding — the first width at which the column no longer
    /// needs to give anything up.
    static let narrowPane: Double = 320
    static let comfortablePane: Double = measureCap + widePadding * 2

    /// The column for a pane of this width.
    ///
    /// The padding ramps between the two widths rather than stepping at a threshold,
    /// for the reason `PageMetrics` gives: a step would make the measure jump
    /// *outwards* as the pane got narrower — cross the boundary going down and the
    /// text suddenly has more room — which reads as a glitch while somebody is
    /// dragging the resize handle. Ramping keeps `measure` monotonic in `width`, which
    /// is the property that keeps the column still (FR-020).
    public static func forPane(width: Double) -> ChatMetrics {
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
        return ChatMetrics(measure: min(measureCap, available), padding: padding)
    }
}
