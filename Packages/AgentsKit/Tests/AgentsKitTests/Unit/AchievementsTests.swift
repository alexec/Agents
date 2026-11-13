import Foundation
import Testing
@testable import AgentsKitCore

/// The achievements' rules (#984): each earned once, back-filled from what the host keeps,
/// and a client's one-time card only for what was just earned.
@Suite("Achievements")
struct AchievementsTests {
    private let start = Date(timeIntervalSince1970: 1_000_000)
    private let cwd = URL(filePath: "/tmp/folder")

    @Test func aAchievementIsEarnedOnceAndKeepsItsFirstDate() {
        var achievements = Achievements()
        let first = achievements.earn(.firstAgent, at: start)
        let second = achievements.earn(.firstAgent, at: start + 60)
        #expect(first && !second)
        #expect(achievements.at(.firstAgent) == start)
        #expect(achievements.earned.count == 1)
    }

    @Test func theListIsEarnedFirstThenTheRestInOrder() {
        var achievements = Achievements()
        achievements.earn(.firstWorkflow, at: start)
        achievements.earn(.firstAgent, at: start + 60)
        let order = achievements.ordered.map(\.achievement)
        #expect(order.prefix(2) == [.firstWorkflow, .firstAgent])
        #expect(Array(order.dropFirst(2)) == Achievement.allCases.filter { $0 != .firstWorkflow && $0 != .firstAgent })
        #expect(!achievements.isComplete)
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
        let facts = Achievements.Facts(agents: [ran, never], devices: [phone], hasWorkflow: true, time: time, calendar: calendar)
        #expect(facts.firstAgent == start)
        #expect(facts.firstPairing == start + 120)
        #expect(facts.fiveAtOnce == UsageChart.date("1970-01-10", calendar: calendar))
        #expect(facts.firstLandedPR == UsageChart.date("1970-01-11", calendar: calendar))

        var achievements = Achievements()
        let now = try #require(UsageChart.date("1970-02-01", calendar: calendar))
        let new = achievements.earn(from: facts, now: now)
        #expect(Set(new) == [.firstAgent, .firstPairing, .firstWorkflow, .firstLandedPR, .fiveAtOnce])
        // Workflows carry no date: earned when first seen.
        #expect(achievements.at(.firstWorkflow) == now)
        let again = achievements.earn(from: facts, now: now)
        #expect(again.isEmpty)
    }

    @Test func aRecordOutlivesTheDaysItCameFrom() {
        var time = TimeHistory()
        time.records.mostAgents = TimeRecord(value: 6, day: "1970-01-05")
        let facts = Achievements.Facts(agents: [Agent](), devices: [Device](), hasWorkflow: false, time: time)
        #expect(facts.fiveAtOnce == UsageChart.date("1970-01-05"))
        time.records.mostAgents = TimeRecord(value: 4, day: "1970-01-05")
        #expect(Achievements.Facts(agents: [Agent](), devices: [Device](), hasWorkflow: false, time: time).fiveAtOnce == nil)
    }

    @Test func aDateAheadOfNowIsNow() {
        var achievements = Achievements()
        achievements.earn(from: Achievements.Facts(firstLandedPR: start + 3600), now: start)
        #expect(achievements.at(.firstLandedPR) == start)
    }

    @Test func theCardIsOnlyForWhatWasJustEarned() {
        var achievements = Achievements()
        achievements.earn(.firstAgent, at: start)
        // A client's first look takes everything so far as seen, back-filled or not.
        let first = achievements.unseen(nil)
        #expect(first.show.isEmpty)
        #expect(first.seen == [Achievement.firstAgent.rawValue])
        achievements.earn(.firstPairing, at: start + 60)
        #expect(achievements.unseen(first.seen).show == [.firstPairing])
    }

    @Test func anUnknownAchievementFromANewerHostIsKept() throws {
        let json = #"{"earned":[{"id":"somethingNew","at":0},{"id":"firstAgent","at":0}]}"#
        let achievements = try JSONDecoder().decode(Achievements.self, from: Data(json.utf8))
        #expect(achievements.earned.count == 2)
        #expect(achievements.has(.firstAgent))
        #expect(achievements.ordered.count == Achievement.allCases.count)
    }

    @Test func aTurnHasRunOnlyOnceOneHasEnded() {
        let start = Date(timeIntervalSince1970: 1000)
        let cwd = URL(filePath: "/tmp/folder")
        let fresh = Agent(runtimeID: "claude", cwd: cwd, state: .starting, createdAt: start, lastActivityAt: start)
        let running = Agent(runtimeID: "claude", cwd: cwd, state: .running, createdAt: start, lastActivityAt: start + 5)
        let queued = Agent(runtimeID: "claude", cwd: cwd, state: .queued, createdAt: start, lastActivityAt: start + 5)
        let finished = Agent(runtimeID: "claude", cwd: cwd, state: .finished, createdAt: start, lastActivityAt: start + 60)
        #expect(!Achievements.hasRunATurn(fresh))
        #expect(!Achievements.hasRunATurn(running))
        #expect(!Achievements.hasRunATurn(queued))
        #expect(Achievements.hasRunATurn(finished))
    }
}
