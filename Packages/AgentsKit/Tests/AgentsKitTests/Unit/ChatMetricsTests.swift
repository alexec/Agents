import Foundation
import Testing
@testable import AgentsKitCore

@Suite("How wide the chat reads")
struct ChatMetricsTests {
    /// The widths the app can produce. The sidebar cannot be opened below a 520-point
    /// window and the project list takes 200 at least, so nothing under 200 reaches a
    /// chat; 2,000 is wider than any display this runs on.
    private let widths = stride(from: 200.0, through: 2_000.0, by: 1)

    // MARK: The four invariants (contracts/ui.md)

    @Test func textAlwaysBeatsMargin() {
        // FR-019, and SC-009: at every width the text is wider than both margins
        // together. Today, at the default window with the sidebar open, it is not.
        for width in widths {
            let metrics = ChatMetrics.forPane(width: width)
            #expect(metrics.measure > metrics.padding * 2,
                    "at \(width)pt the margin (\(metrics.padding * 2)) beat the text (\(metrics.measure))")
        }
    }

    @Test func theColumnNeverExceedsTheCap() {
        // FR-017. A large display gets margin, not line length.
        for width in widths {
            #expect(ChatMetrics.forPane(width: width).measure <= ChatMetrics.measureCap)
        }
    }

    @Test func theMarginHasAFloor() {
        // FR-018. The padding gives way, and then stops giving.
        for width in widths {
            #expect(ChatMetrics.forPane(width: width).padding >= ChatMetrics.tightPadding)
        }
    }

    /// The property the resize handle rests on. A step in the padding rather than a
    /// ramp would make the measure jump outwards as the pane narrowed, which reads as
    /// the column glitching while somebody drags (FR-020).
    @Test func wideningThePaneNeverNarrowsTheText() {
        var previous = ChatMetrics.forPane(width: 200).measure
        for width in stride(from: 201.0, through: 2_000.0, by: 1) {
            let measure = ChatMetrics.forPane(width: width).measure
            #expect(measure >= previous, "measure shrank going from \(width - 1) to \(width)")
            previous = measure
        }
    }

    // MARK: The two anchors that make it the right cap rather than merely a consistent one

    @Test func theDefaultWindowWithTheSidebarOpenIsMostlyText() {
        // 480 is the pane at the default window with the sidebar at its stored
        // default. The old gutter left 192 of text inside 288 of margin here; this is
        // the reported symptom, reachable at default settings.
        let metrics = ChatMetrics.forPane(width: 480)
        #expect(metrics.measure > 400)
        #expect(metrics.measure > metrics.padding * 4)
    }

    @Test func theDefaultWindowWithTheSidebarShutBarelyChanges() {
        // 860 is the pane with the sidebar shut, where the old gutter gave 572 of
        // text. The cap is set beside that so the look at the default size holds.
        let metrics = ChatMetrics.forPane(width: 860)
        #expect(metrics.measure == ChatMetrics.measureCap)
        #expect(abs(metrics.measure - 572) <= 12)
        #expect(metrics.padding == ChatMetrics.widePadding)
    }

    @Test func aWidePaneCentresTheSurplus() {
        // Past the cap the column stops growing; what is left over is margin, and
        // the view splits it either side (FR-020).
        let wide = ChatMetrics.forPane(width: 1_600)
        #expect(wide.measure == ChatMetrics.measureCap)
        #expect(wide.padding == ChatMetrics.widePadding)
    }

    @Test func theNarrowestPaneGivesUpItsPaddingRatherThanItsText() {
        let narrow = ChatMetrics.forPane(width: 300)
        #expect(narrow.padding == ChatMetrics.tightPadding)
        #expect(narrow.measure == 300 - ChatMetrics.tightPadding * 2)
    }

    @Test func aPaneTooNarrowToHoldAnythingAsksForNothingImpossible() {
        // Not reachable through the window, but arithmetic that returns a negative
        // width is arithmetic waiting to be handed to a view.
        #expect(ChatMetrics.forPane(width: 10).measure >= 0)
        #expect(ChatMetrics.forPane(width: 0).measure == 0)
    }
}
