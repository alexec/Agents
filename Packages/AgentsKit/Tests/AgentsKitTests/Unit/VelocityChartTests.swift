import Foundation
import Testing
@testable import AgentsKitCore

/// The Velocity page's bars (#4597): the PRs that landed, by range, with the daily average,
/// the shares by repository and the reverts among them.
@Suite("Velocity chart")
struct VelocityChartTests {
    private let pacific: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return calendar
    }()

    private let agents = "github:alexec/agents"
    private let site = "github:alexec/agents-site"

    /// Monday 9 November 2026 at 20:00: three PRs at 14:00 today, five on Sunday (one a revert),
    /// and two on 1 October, inside 3M and outside M.
    private var history: VelocityHistory {
        VelocityHistory(
            hours: ["2026-11-09T14": [agents: VelocityBucket(merged: 2), site: VelocityBucket(merged: 1)]],
            days: ["2026-11-09": [agents: VelocityBucket(merged: 2), site: VelocityBucket(merged: 1)],
                   "2026-11-08": [agents: VelocityBucket(merged: 5, reverted: 1)],
                   "2026-10-01": [agents: VelocityBucket(merged: 2)]],
            now: "2026-11-09T20", timeZone: "America/Los_Angeles")
    }

    @Test("W is the last seven days, today last, with the average over the days that had any")
    func week() {
        let chart = VelocityChart(history, range: .week, calendar: pacific)
        #expect(chart.bars.count == 7)
        #expect(chart.bars.last?.stamp == "2026-11-09")
        #expect(chart.bars.last?.merged == 3)
        #expect(chart.bars.dropLast().last?.merged == 5)
        #expect(chart.total == 8)
        #expect(chart.reverted == 1)
        #expect(chart.average == 4)
        #expect(chart.revertsLine == "Including 1 revert.")
        #expect(chart.shares.map(\.name) == ["alexec/agents", "alexec/agents-site"])
        #expect(chart.shares.map(\.merged) == [7, 1])
    }

    @Test("D is today by the hour, and its figure is the day's total")
    func day() {
        let chart = VelocityChart(history, range: .day, calendar: pacific)
        #expect(chart.bars.count == 24)
        #expect(chart.bars.first { $0.stamp == "2026-11-09T14" }?.merged == 3)
        #expect(chart.total == 3)
        #expect(chart.average == 3)
        #expect(chart.revertsLine == "No reverts.")
    }

    @Test("3M is thirteen weeks ending today, so October's PRs are in it and not in M")
    func threeMonths() {
        let quarter = VelocityChart(history, range: .threeMonths, calendar: pacific)
        #expect(quarter.bars.count == 13)
        #expect(quarter.bars.last?.merged == 8)
        #expect(quarter.total == 10)
        #expect(quarter.average == 10.0 / 3)
        #expect(VelocityChart(history, range: .month, calendar: pacific).total == 8)
    }

    @Test("a range with nothing in it is empty")
    func empty() {
        let chart = VelocityChart(VelocityHistory(now: "2026-11-09T20"), range: .week, calendar: pacific)
        #expect(chart.isEmpty)
        #expect(chart.bars.count == 7)
        #expect(chart.shares.isEmpty)
        #expect(chart.average == 0)
    }

    @Test("counts read as PRs, an average under 10 to one decimal")
    func words() {
        #expect(VelocityChart.words(0) == "0 PRs")
        #expect(VelocityChart.words(1) == "1 PR")
        #expect(VelocityChart.words(2.4) == "2.4 PRs")
        #expect(VelocityChart.words(46.4) == "46 PRs")
        #expect(VelocityChart.repoName("alexec/agents") == "alexec/agents")
    }

    @Test("a host in another zone moves into the viewer's days")
    func merged() {
        let utc = VelocityHistory(hours: ["2026-11-10T02": [agents: VelocityBucket(merged: 1)]],
                                  days: ["2026-11-10": [agents: VelocityBucket(merged: 1)]],
                                  now: "2026-11-10T04", timeZone: "UTC")
        let here = VelocityHistory.merged([utc], calendar: pacific)
        #expect(here.days["2026-11-09"]?[agents]?.merged == 1)
        #expect(here.days["2026-11-10"] == nil)
    }
}
