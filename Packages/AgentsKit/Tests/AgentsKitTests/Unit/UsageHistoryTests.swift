import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// The history behind the usage charts (#823): bounded, by runtime, and seeded once.
@Suite("What the work used over time")
struct UsageHistoryTests {
    private func temporary() -> StoreLocations {
        StoreLocations(root: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsUsageHistoryTests-\(UUID().uuidString)", isDirectory: true))
    }

    private func at(_ text: String) -> Date {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        f.timeZone = TimeZone.current
        return f.date(from: text)!
    }

    private func usd(_ amount: Decimal) -> Cost { Cost(amount: amount, currency: "USD") }

    private func turn(input: Int = 10, output: Int = 5, cacheRead: Int = 1000) -> TurnUsage {
        TurnUsage(totalTokens: input + output + cacheRead, inputTokens: input, outputTokens: output,
                  cachedReadTokens: cacheRead)
    }

    @Test("a turn is kept by its hour and by its day, per runtime, and survives a restart")
    func aTurnIsKeptInBothTiers() throws {
        let locations = temporary()
        let ledger = UsageLedger(locations: locations, now: at("2026-10-12 09:00"))
        ledger.record(turn(), priced: true, runtime: "claude", on: at("2026-10-12 14:20"))
        ledger.record(usd(2), runtime: "claude", on: at("2026-10-12 14:30"))
        ledger.record(turn(input: 1, output: 1, cacheRead: 0), priced: false, runtime: "grok", on: at("2026-10-12 15:00"))
        try ledger.flush()

        let history = UsageLedger(locations: locations).history(at: at("2026-10-12 16:00"))
        #expect(history.now == "2026-10-12T16")
        #expect(history.hours["2026-10-12T14"]?["claude"]?.cost == ["USD": 2])
        #expect(history.hours["2026-10-12T14"]?["claude"]?.inputTokens == 10)
        #expect(history.days["2026-10-12"]?["claude"]?.cachedReadTokens == 1000)
        #expect(history.days["2026-10-12"]?["grok"]?.unpricedTurns == 1)
        #expect(history.days["2026-10-12"]?["claude"]?.turns == 1)
    }

    @Test("the file never holds more than 168 hours and 90 days")
    func theHistoryIsBounded() throws {
        let locations = temporary()
        let ledger = UsageLedger(locations: locations)
        var date = at("2026-06-01 00:00")
        for _ in 0..<(120 * 4) {
            ledger.record(turn(), priced: true, runtime: "claude", on: date)
            date = date.addingTimeInterval(6 * 3600)
        }
        try ledger.flush()
        let history = UsageLedger(locations: locations).history(at: date)
        #expect(history.hours.count == UsageHistory.hoursKept)
        #expect(history.days.count == UsageHistory.daysKept)
        #expect(history.days.keys.max() == UsageChart.dayStamp(date.addingTimeInterval(-6 * 3600)),
                "what is dropped is the oldest")
    }

    @Test("a first run is seeded from the spend ledger and the transcripts made before it")
    func aFirstRunIsSeeded() throws {
        let locations = temporary()
        try FileManager.default.createDirectory(at: locations.root, withIntermediateDirectories: true)
        try Data(#"{"days":{"2026-10-11":{"USD":12.5}}}"#.utf8).write(to: locations.spend)
        let id = UUID()
        try FileManager.default.createDirectory(at: locations.agent(id), withIntermediateDirectories: true)
        try Data(#"{"runtimeID":"codex"}"#.utf8).write(to: locations.record(id))
        let lines = [
            #"{"at":"2026-10-11T10:05:00.000Z","id":"\#(UUID())","kind":{"usageRecorded":{"_0":{"inputTokens":7,"outputTokens":3,"totalTokens":10}}}}"#,
            #"{"at":"2026-10-11T10:06:00.000Z","id":"\#(UUID())","kind":{"userMessage":{"_0":"usageRecorded is only words here"}}}"#,
            // After the ledger was made: the daemon records this one itself.
            #"{"at":"2026-10-12T12:00:00.000Z","id":"\#(UUID())","kind":{"usageRecorded":{"_0":{"inputTokens":100,"outputTokens":0,"totalTokens":100}}}}"#,
        ]
        try Data(lines.joined(separator: "\n").utf8).write(to: locations.transcript(id))

        let made = ISO8601DateFormatter().date(from: "2026-10-12T11:00:00Z")!
        let ledger = UsageLedger(locations: locations, now: made)
        ledger.seedIfNeeded()
        let history = ledger.history(at: made)
        let seededDay = UsageChart.dayStamp(ISO8601DateFormatter().date(from: "2026-10-11T10:05:00Z")!)
        #expect(history.days["2026-10-11"]?[UsageHistory.unattributed]?.cost == ["USD": 12.5])
        #expect(history.days[seededDay]?["codex"]?.inputTokens == 7)
        let codexInput = history.days.values.compactMap { $0["codex"]?.inputTokens }.reduce(0, +)
        #expect(codexInput == 7, "nothing after the ledger was made is seeded")
        #expect(FileManager.default.fileExists(atPath: locations.usageHistory.path))

        // A second run has a file and seeds nothing more.
        let again = UsageLedger(locations: locations, now: made)
        again.seedIfNeeded()
        #expect(again.history(at: made).days[seededDay]?["codex"]?.inputTokens == 7)
    }

    // MARK: The chart

    private func history() -> UsageHistory {
        var history = UsageHistory(now: "2026-10-12T16")
        history.add(UsageBucket(cost: ["USD": 4], inputTokens: 100, outputTokens: 50, cachedReadTokens: 9000, turns: 1),
                    runtime: "claude", hour: "2026-10-12T09")
        history.add(UsageBucket(cost: ["USD": 1], inputTokens: 10, turns: 1), runtime: "codex", hour: "2026-10-12T15")
        history.add(UsageBucket(cost: ["USD": 6], turns: 1), runtime: "claude", hour: "2026-10-10T11")
        history.add(UsageBucket(inputTokens: 5, turns: 1, unpricedTurns: 1), runtime: "grok", hour: "2026-10-10T11")
        history.add(UsageBucket(cost: ["USD": 100]), runtime: "claude", hour: "2026-06-01T11")
        return history
    }

    @Test("D is today by the hour")
    func dayIsHourly() {
        let chart = UsageChart(history(), range: .day, metric: .cost)
        #expect(chart.bars.count == 24)
        #expect(chart.bars[9].value == 4)
        #expect(chart.bars[15].value == 1)
        #expect(chart.total == 5)
        #expect(chart.headline == "Total")
        #expect(chart.shares.map(\.runtime) == ["claude", "codex"])
    }

    @Test("W is seven days, and the average is over the days that have any")
    func weekIsDaily() {
        let chart = UsageChart(history(), range: .week, metric: .cost)
        #expect(chart.bars.count == 7)
        #expect(chart.bars.last?.stamp == "2026-10-12")
        #expect(chart.bars.last?.value == 5)
        #expect(chart.total == 11)
        #expect(chart.average == 5.5)
        #expect(chart.unpricedTurns == 1)
    }

    @Test("3M is thirteen weeks, the last ending today")
    func threeMonthsIsWeekly() {
        let chart = UsageChart(history(), range: .threeMonths, metric: .cost)
        #expect(chart.bars.count == 13)
        #expect(chart.bars.last?.value == 11)
        #expect(chart.total == 11, "June is past the thirteen weeks")
    }

    @Test("tokens draw what was asked and answered, and say the cache reads apart")
    func tokensLeaveCacheReadsOut() {
        let chart = UsageChart(history(), range: .day, metric: .tokens)
        #expect(chart.total == 160)
        #expect(chart.cachedReadTokens == 9000)
        #expect(chart.currency == nil)
        #expect(UsageChart.tokenWords(716_000_000) == "716M")
    }
}
