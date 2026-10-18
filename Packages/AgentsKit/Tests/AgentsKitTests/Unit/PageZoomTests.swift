import AgentsKitCore
import Testing

/// The page's text zoom (#1419).
struct PageZoomTests {
    @Test func zoomInGoesOneStepAndStopsAtTheLargest() {
        #expect(PageZoom.larger(than: 1) == 1.1)
        #expect(PageZoom.larger(than: 1.75) == 2)
        #expect(PageZoom.larger(than: 2) == 2)
        #expect(!PageZoom.canZoomIn(2))
        #expect(PageZoom.canZoomIn(1))
    }

    @Test func zoomOutGoesOneStepAndStopsAtTheSmallest() {
        #expect(PageZoom.smaller(than: 1) == 0.9)
        #expect(PageZoom.smaller(than: 0.9) == 0.75)
        #expect(PageZoom.smaller(than: 0.75) == 0.75)
        #expect(!PageZoom.canZoomOut(0.75))
    }

    @Test func aLevelThatIsNotAStepSnapsToTheNearest() {
        #expect(PageZoom.snapped(1.3) == 1.25)
        #expect(PageZoom.snapped(9) == 2)
        #expect(PageZoom.snapped(0) == 0.75)
        #expect(PageZoom.snapped(.nan) == 1)
        // From a level between steps, ⌘+ goes to the step above the nearest.
        #expect(PageZoom.larger(than: 1.3) == 1.5)
    }

    @Test func aPinchLandsOnAStep() {
        #expect(PageZoom.pinched(from: 1, by: 1.02) == 1)
        #expect(PageZoom.pinched(from: 1, by: 1.5) == 1.5)
        #expect(PageZoom.pinched(from: 1.5, by: 3) == 2)
        #expect(PageZoom.pinched(from: 1, by: 0.1) == 0.75)
    }

    @Test func theMeasureGrowsWithTheTextUntilThePaneStopsIt() {
        // The same number of words on a line: the cap grows with the zoom.
        #expect(PageMetrics.forPane(width: 2000, zoom: 1.5).measure == PageMetrics.measureCap * 1.5)
        #expect(PageMetrics.forPane(width: 2000).measure == PageMetrics.measureCap)
        // A pane narrower than that still holds the text inside it.
        let narrow = PageMetrics.forPane(width: 460, zoom: 2)
        #expect(narrow.measure == 460 - 2 * PageMetrics.widePadding)
    }
}
