import Testing
@testable import AgentsKitCore

@Suite("Where a pane goes on a phone or an iPad")
struct PanePlacementTests {
    @Test(arguments: [1_180.0, 1_366.0])
    func anIPadInLandscapeTakesAColumn(width: Double) {
        #expect(PanePlacement.decide(width: width) == .column(paneWidth: PanePlacement.minimumPaneWidth))
    }

    @Test(arguments: [820.0, 1_024.0 - 4, 390.0, 430.0])
    func anythingNarrowerTakesTheScreen(width: Double) {
        #expect(PanePlacement.decide(width: width) == .fullScreen)
    }

    @Test func theThresholdIsTheChatsReadingWidthAndAPane() {
        #expect(PanePlacement.columnThreshold == 1_021)
        #expect(PanePlacement.decide(width: 1_021) != .fullScreen)
        #expect(PanePlacement.decide(width: 1_020.5) == .fullScreen)
    }

    @Test func aDraggedWidthIsHeldBetweenTheMinimumAndHalfTheWindow() {
        #expect(PanePlacement.decide(width: 1_366, preferredPaneWidth: 500) == .column(paneWidth: 500))
        #expect(PanePlacement.decide(width: 1_366, preferredPaneWidth: 900) == .column(paneWidth: 683))
        #expect(PanePlacement.decide(width: 1_366, preferredPaneWidth: 100) == .column(paneWidth: 360))
    }
}
