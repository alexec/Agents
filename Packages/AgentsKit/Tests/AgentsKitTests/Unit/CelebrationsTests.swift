import Foundation
import Testing
@testable import AgentsKitCore

/// The Blob's celebrations (#986): only for pull requests counted after the first count,
/// confetti for the day's first and a milestone, and one held merging with the next.
@MainActor
@Suite("Celebrations")
struct CelebrationsTests {
    private let days = ["2026-10-15", "2026-10-14"]

    @Test func theFirstCountCelebratesNothing() {
        let history = TimeHistory()
        #expect(history.landed(["2026-10-15": 3], on: days, today: days[0]) == nil)
    }

    @Test func moreThanTheLastCountLandedAndTheDaysFirstIsSaid() {
        var history = TimeHistory()
        history.setPRsMerged(["2026-10-14": 2], on: days)
        #expect(history.landed(["2026-10-14": 2], on: days, today: days[0]) == nil)
        #expect(history.landed(["2026-10-14": 2, "2026-10-15": 1], on: days, today: days[0])
            == PRsLanded(count: 1, firstToday: true))
        history.setPRsMerged(["2026-10-14": 2, "2026-10-15": 1], on: days)
        // A late one on yesterday and a second today: two, and not the day's first.
        #expect(history.landed(["2026-10-14": 3, "2026-10-15": 2], on: days, today: days[0])
            == PRsLanded(count: 2, firstToday: false))
    }

    @Test func aHeldCelebrationMergesWithTheNextAndIsLetGo() throws {
        let model = AgentsModel()
        model.apply(.prsLanded(PRsLanded(count: 1, firstToday: true)))
        model.apply(.prsLanded(PRsLanded(count: 1, firstToday: false)))
        let held = try #require(model.celebration)
        #expect(held.id == 2 && held.confetti)
        model.celebrated(Celebration(id: 1, confetti: true))
        #expect(model.celebration == held)
        model.celebrated(held)
        #expect(model.celebration == nil)
    }

    @Test func aMilestoneEarnedWhileLookingHasConfetti() {
        let model = AgentsModel()
        var milestones = Milestones()
        milestones.earn(.firstAgent, at: Date(timeIntervalSince1970: 0))
        // The first look is not news.
        model.apply(.milestonesChanged(milestones))
        #expect(model.celebration == nil)
        milestones.earn(.firstWorkflow, at: Date(timeIntervalSince1970: 60))
        model.apply(.milestonesChanged(milestones))
        #expect(model.celebration?.confetti == true)
    }
}
