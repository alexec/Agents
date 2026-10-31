import Foundation
import Testing
@testable import AgentsKitCore

/// The milestones' rules (#984): each earned once, back-filled from what the host keeps,
/// and a client's one-time card only for what was just earned.
@Suite("Milestones")
struct MilestonesTests {
    private let start = Date(timeIntervalSince1970: 1_000_000)
    private let cwd = URL(filePath: "/tmp/folder")

    @Test func aMilestoneIsEarnedOnceAndKeepsItsFirstDate() {
        var milestones = Milestones()
        let first = milestones.earn(.firstAgent, at: start)
        let second = milestones.earn(.firstAgent, at: start + 60)
        #expect(first && !second)
        #expect(milestones.at(.firstAgent) == start)
        #expect(milestones.earned.count == 1)
    }

    @Test func theListIsEarnedFirstThenTheRestInOrder() {
        var milestones = Milestones()
        milestones.earn(.firstWorkflow, at: start)
        milestones.earn(.firstAgent, at: start + 60)
        let order = milestones.ordered.map(\.milestone)
        #expect(order.prefix(2) == [.firstWorkflow, .firstAgent])
        #expect(Array(order.dropFirst(2)) == Milestone.allCases.filter { $0 != .firstWorkflow && $0 != .firstAgent })
        #expect(!milestones.isComplete)
    }

    @Test func recordsBackFillWhatTheySay() throws {
        let calendar = Calendar(identifier: .gregorian)
        let ran = Agent(runtimeID: "claude", cwd: cwd, state: .finished, createdAt: start, lastActivityAt: start + 60)
        let never = Agent(runtimeID: "claude", cwd: cwd, state: .starting, createdAt: start - 600, lastActivityAt: start - 600)
        let phone = Device(id: UUID(), name: "iPhone", kind: .iPhone, announcedAt: start + 120)
        var time = TimeHistory()
        time.changeRecap("1970-01-10") { $0.peakAgents = 5 }
        time.changeRecap("1970-01-11") { $0.prsMerged = 2 }
        time.changeRecap("1970-01-09") { $0.prsMerged = 0; $0.peakAgents = 3 }
        let facts = Milestones.Facts(agents: [ran, never], devices: [phone], hasWorkflow: true, time: time, calendar: calendar)
        #expect(facts.firstAgent == start)
        #expect(facts.firstPairing == start + 120)
        #expect(facts.fiveAtOnce == UsageChart.date("1970-01-10", calendar: calendar))
        #expect(facts.firstLandedPR == UsageChart.date("1970-01-11", calendar: calendar))

        var milestones = Milestones()
        let now = try #require(UsageChart.date("1970-02-01", calendar: calendar))
        let new = milestones.earn(from: facts, now: now)
        #expect(Set(new) == [.firstAgent, .firstPairing, .firstWorkflow, .firstLandedPR, .fiveAtOnce])
        // Workflows carry no date: earned when first seen.
        #expect(milestones.at(.firstWorkflow) == now)
        let again = milestones.earn(from: facts, now: now)
        #expect(again.isEmpty)
    }

    @Test func aRecordOutlivesTheDaysItCameFrom() {
        var time = TimeHistory()
        time.records.mostAgents = TimeRecord(value: 6, day: "1970-01-05")
        let facts = Milestones.Facts(agents: [Agent](), devices: [Device](), hasWorkflow: false, time: time)
        #expect(facts.fiveAtOnce == UsageChart.date("1970-01-05"))
        time.records.mostAgents = TimeRecord(value: 4, day: "1970-01-05")
        #expect(Milestones.Facts(agents: [Agent](), devices: [Device](), hasWorkflow: false, time: time).fiveAtOnce == nil)
    }

    @Test func aDateAheadOfNowIsNow() {
        var milestones = Milestones()
        milestones.earn(from: Milestones.Facts(firstLandedPR: start + 3600), now: start)
        #expect(milestones.at(.firstLandedPR) == start)
    }

    @Test func theCardIsOnlyForWhatWasJustEarned() {
        var milestones = Milestones()
        milestones.earn(.firstAgent, at: start)
        // A client's first look takes everything so far as seen, back-filled or not.
        let first = milestones.unseen(nil)
        #expect(first.show.isEmpty)
        #expect(first.seen == [Milestone.firstAgent.rawValue])
        milestones.earn(.firstPairing, at: start + 60)
        #expect(milestones.unseen(first.seen).show == [.firstPairing])
    }

    @Test func anUnknownMilestoneFromANewerHostIsKept() throws {
        let json = #"{"earned":[{"id":"somethingNew","at":0},{"id":"firstAgent","at":0}]}"#
        let milestones = try JSONDecoder().decode(Milestones.self, from: Data(json.utf8))
        #expect(milestones.earned.count == 2)
        #expect(milestones.has(.firstAgent))
        #expect(milestones.ordered.count == Milestone.allCases.count)
    }
}
