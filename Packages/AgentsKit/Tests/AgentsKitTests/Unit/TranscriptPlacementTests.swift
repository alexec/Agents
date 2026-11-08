import AgentsKitCore
import Testing

/// Where the transcript's rows go, and that nothing on screen moves under a reader (#2310).
struct TranscriptPlacementTests {
    /// Following the end: the rows go down from the slack, one after another.
    @Test func followingPlacesDownFromTheSlack() {
        let placed = TranscriptPlacement.place(heights: [100, 50, 200], slack: 30, anchor: nil, reserve: 1000)
        #expect(placed.tops == [30, 130, 180])
        #expect(placed.height == 380)
        #expect(placed.slack == 30)
        #expect(placed.shift == 0)
    }

    /// Reading back: the anchor stays where it was, and the rows above it go up from it.
    @Test func theAnchorStaysWhereItIs() {
        let placed = TranscriptPlacement.place(heights: [100, 50, 200, 80], slack: 0,
                                               anchor: (index: 2, top: 900), reserve: 1000)
        #expect(placed.tops == [750, 850, 900, 1100])
        #expect(placed.slack == 750)
        #expect(placed.height == 1180)
    }

    /// An earlier page lands above the reader: its rows take the slack, and the line read
    /// and everything below it are where they were.
    @Test func anEarlierPageTakesTheSlack() throws {
        let before = TranscriptPlacement.place(heights: [100, 200, 80], slack: 2000, anchor: nil, reserve: 2000)
        try #require(before.tops.count == 3)
        let anchor = (index: 1, top: before.tops[1])
        let after = TranscriptPlacement.place(heights: [300, 300, 300, 100, 200, 80], slack: before.slack,
                                              anchor: (index: anchor.index + 3, top: anchor.top), reserve: 2000)
        try #require(after.tops.count == 6)
        #expect(Array(after.tops[4...]) == Array(before.tops[1...]))
        #expect(after.slack == before.slack - 900)
        #expect(after.height == before.height)
        #expect(after.shift == 0)
    }

    /// A row above the reader grows (its steps came, or it was measured for the first time):
    /// the rows below it do not move.
    @Test func aRowAboveGrowingMovesNothingBelowIt() throws {
        let anchor = (index: 3, top: 5000.0)
        let before = TranscriptPlacement.place(heights: [160, 160, 160, 120, 400], slack: 0, anchor: anchor, reserve: 3000)
        let after = TranscriptPlacement.place(heights: [160, 900, 160, 120, 400], slack: 0, anchor: anchor, reserve: 3000)
        try #require(before.tops.count == 5 && after.tops.count == 5)
        #expect(after.slack == before.slack - 740)
        #expect(after.tops[3...] == before.tops[3...])
    }

    /// The slack runs out: everything moves down by enough to leave the reserve again, and
    /// says by how much, so the pane can move with it.
    @Test func runningOutOfSlackShiftsOnce() {
        let placed = TranscriptPlacement.place(heights: [500, 500, 100], slack: 0,
                                               anchor: (index: 2, top: 300), reserve: 1000)
        #expect(placed.shift == 1700)
        #expect(placed.tops == [1000, 1500, 2000])
        #expect(placed.slack == 1000)
    }

    /// The window is the rows that meet the span, and no others.
    @Test func theWindowIsTheRowsInTheSpan() {
        let tops: [Double] = [0, 100, 200, 300, 400]
        let heights: [Double] = [100, 100, 100, 100, 100]
        #expect(TranscriptPlacement.window(tops: tops, heights: heights, from: 150, to: 320) == 1..<4)
        #expect(TranscriptPlacement.window(tops: tops, heights: heights, from: 100, to: 200) == 1..<2)
        #expect(TranscriptPlacement.window(tops: tops, heights: heights, from: 600, to: 900).isEmpty)
        #expect(TranscriptPlacement.window(tops: [], heights: [], from: 0, to: 10).isEmpty)
    }

    /// The anchor is the first row that starts on screen.
    @Test func theAnchorIsTheFirstRowStartingOnScreen() {
        let tops: [Double] = [0, 100, 300, 600]
        let heights: [Double] = [100, 200, 300, 100]
        let anchor = TranscriptPlacement.anchor(tops: tops, heights: heights, visibleTop: 150, visibleBottom: 650)
        #expect(anchor?.index == 2)
        #expect(anchor?.top == 300)
    }

    /// Reading far back, a page that lands above leaves the margin where it is: moving it
    /// moved the screen for a frame (#4087).
    @Test func aReaderFarBackKeepsTheMargin() {
        #expect(!TranscriptPlacement.marginFollows(slack: 489_000, margin: 500_000, top: 503_000,
                                                   pane: 800, following: false))
    }

    /// A reader near the margin, or at it as a page lands, needs the rows it hid: it moves.
    @Test func aReaderNearTheTopTakesTheMargin() {
        #expect(TranscriptPlacement.marginFollows(slack: 489_000, margin: 500_000, top: 500_000,
                                                  pane: 800, following: false))
        #expect(TranscriptPlacement.marginFollows(slack: 500_300, margin: 500_000, top: 501_500,
                                                  pane: 800, following: false))
    }

    /// Following the end, the margin follows the slack at once; with no change, never.
    @Test func followingAlwaysTakesTheMargin() {
        #expect(TranscriptPlacement.marginFollows(slack: 489_000, margin: 500_000, top: 520_000,
                                                  pane: 800, following: true))
        #expect(!TranscriptPlacement.marginFollows(slack: 500_000.2, margin: 500_000, top: 500_000,
                                                   pane: 800, following: false))
    }

    /// A row taller than the screen holds the place by itself.
    @Test func aRowTallerThanTheScreenIsItsOwnAnchor() {
        let anchor = TranscriptPlacement.anchor(tops: [0, 100, 3000], heights: [100, 2900, 50],
                                                visibleTop: 500, visibleBottom: 1300)
        #expect(anchor?.index == 1)
        #expect(anchor?.top == 100)
    }
}
