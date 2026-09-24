import Foundation
import Testing
@testable import AgentsKit

@Suite("How wide a document reads")
struct PageMetricsTests {
    /// Measured on this Mac with real prose, not with an average character. The
    /// document face is the app's `reading` step — the system sans at 15pt — since the
    /// type scale was made the whole app's. It was New York at 12pt and 5.56 when 007
    /// wrote these; see research section 6.
    private let advance = 6.83

    private func characters(at width: Double) -> Int {
        Int((PageMetrics.forPane(width: width).measure / advance).rounded())
    }

    @Test func theDefaultPaneWidthClearsTheFloor() {
        // SC-003 asks for 60 to 90 characters at the pane's default width, which
        // `SidebarFrame` puts at 460. The floor is what fixes that width: at the
        // reading step a pane of 380 yields 50 and misses, so the pane widened rather
        // than the text shrinking back.
        #expect(characters(at: 460) >= 60)
        #expect(characters(at: 460) <= 90)
    }

    @Test func theWidestPaneStillReadsAtNinetyCharacters() {
        // Uncapped, a 900pt pane would run to 126 characters.
        #expect(characters(at: 900) <= 90)
        #expect(PageMetrics.forPane(width: 900).measure == PageMetrics.measureCap)
    }

    @Test func theNarrowestPaneGivesUpItsPaddingRatherThanItsText() {
        // FR-005. Below the floor on purpose: 37 characters that fit beat 60 that
        // do not.
        let narrow = PageMetrics.forPane(width: 280)
        #expect(narrow.padding == PageMetrics.tightPadding)
        #expect(narrow.measure == 256)
    }

    @Test func aComfortablePaneKeepsItsFullPadding() {
        #expect(PageMetrics.forPane(width: 460).padding == PageMetrics.widePadding)
        #expect(PageMetrics.forPane(width: 620).padding == PageMetrics.widePadding)
    }

    @Test func themeasureNeverExceedsTheCap() {
        for width in stride(from: 200.0, through: 1400.0, by: 1) {
            #expect(PageMetrics.forPane(width: width).measure <= PageMetrics.measureCap)
        }
    }

    /// The property the resize handle rests on. A step in the padding rather than a
    /// ramp would make the measure jump outwards as the pane narrowed, which reads as
    /// the page glitching while somebody drags.
    @Test func wideningThePaneNeverNarrowsTheText() {
        var previous = PageMetrics.forPane(width: 200).measure
        for width in stride(from: 201.0, through: 1400.0, by: 1) {
            let measure = PageMetrics.forPane(width: width).measure
            #expect(measure >= previous, "measure shrank going from \(width - 1) to \(width)")
            previous = measure
        }
    }

    @Test func aPaneTooNarrowToHoldAnythingAsksForNothingImpossible() {
        // Not reachable through `SidebarFrame`, which clamps at 280, but arithmetic
        // that returns a negative width is arithmetic waiting to be handed to a view.
        #expect(PageMetrics.forPane(width: 10).measure >= 0)
        #expect(PageMetrics.forPane(width: 0).measure == 0)
    }
}
