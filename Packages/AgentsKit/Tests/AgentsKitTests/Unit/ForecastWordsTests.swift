import Foundation
import Testing
@testable import AgentsKitCore

/// #4527: an epic's forecast on Work's epic page, as `Web/test/forecast.test.mjs` has it.
@Suite("Forecast words")
struct ForecastWordsTests {
    typealias Range = DaemonAPI.LineageEstimateRange
    let utc = TimeZone(identifier: "UTC")!
    let gb = Locale(identifier: "en_GB")
    /// Tue 10 Nov 2026, 12:00 UTC.
    let now = Date(timeIntervalSince1970: 1_794_312_000)

    func forecast(lands: DaemonAPI.LineageForecastLands? = nil, noForecast: String? = nil,
                  toComplete: DaemonAPI.LineageForecastToComplete? = nil,
                  kept: DaemonAPI.LineageForecastKept? = nil) -> DaemonAPI.LineageForecast {
        .init(node: .init(kind: "issue", ref: "github:alexec/Agents#1"), at: now, windowDays: 14, landings: 400,
              lands: lands, noForecast: noForecast, toComplete: toComplete, kept: kept, burn: [], serviceLevels: [])
    }

    func days(_ n: Double) -> Date { now.addingTimeInterval(n * 86400) }

    @Test func anOpenEpicSaysWhenItLikelyLands() {
        let f = forecast(lands: .init(p50: days(8), p85: days(11), open: 6, closed: 2, stepsLeft: 3, share: 0.062, groups: 12))
        #expect(ForecastWords.landsLine(f, timeZone: utc, locale: gb)
            == "Likely lands by Wed 18 Nov (85%: by Sat 21 Nov), at the last 14 days' pace")
        #expect(ForecastWords.help(f) == "For the 6 open children filed now, not ones still to come: 1,000 draws of the last "
            + "14 days' landings, hour by hour, of which an epic gets 6.2%, the median of 12 closed epics. "
            + "The 3 blocked-by steps left do not move the date.")
    }

    @Test func aForecastForTheNextTwoDaysSaysTheHour() {
        let f = forecast(lands: .init(p50: now.addingTimeInterval(3 * 3600), p85: now.addingTimeInterval(9 * 3600),
                                      open: 1, closed: 4, stepsLeft: 1, share: 0.05, groups: 5))
        #expect(ForecastWords.landsLine(f, timeZone: utc, locale: gb)
            == "Likely lands by Tue 10 Nov, 15:00 (85%: by Tue 10 Nov, 21:00), at the last 14 days' pace")
        #expect(ForecastWords.help(f)?.hasSuffix("the median of 5 closed epics.") == true)
    }

    @Test func noDateSaysWhyUnlessThereIsNothingToSay() {
        #expect(ForecastWords.landsLine(forecast(noForecast: "fewer than 5 closed epics"))
            == "No landing forecast: fewer than 5 closed epics")
        #expect(ForecastWords.landsLine(forecast(noForecast: "no open children")) == nil)
        #expect(ForecastWords.landsLine(forecast(noForecast: "not an epic")) == nil)
        #expect(ForecastWords.help(forecast()) == nil)
        #expect(ForecastWords.toCompleteLine(forecast()) == nil)
    }

    @Test func theEstimateToCompleteIsARoundedRange() {
        var t = DaemonAPI.LineageForecastToComplete(cost: ["USD": Range(median: 95, p10: 58, p90: 141)], ratio: 1.31,
                                                    closed: 4, leadRatio: 0.1)
        #expect(ForecastWords.toCompleteLine(forecast(toComplete: t)) == "To complete: about $60 to $100")
        #expect(ForecastWords.help(forecast(toComplete: t))
            == "To complete: the open children's estimates × 1.31, as the 4 closed children cost against theirs, plus 10% for the lead.")
        t.loaded = ["USD": Range(median: 130, p10: 80, p90: 190)]
        t.leadRatio = 0
        #expect(ForecastWords.toCompleteLine(forecast(toComplete: t)) == "To complete: about $60 to $100 ($80 to $200 all in)")
        #expect(ForecastWords.help(forecast(toComplete: t))
            == "To complete: the open children's estimates × 1.31, as the 4 closed children cost against theirs. All in adds the cost no issue links to.")
        t.loaded = ["USD": Range(median: 96, p10: 62, p90: 144)]
        #expect(ForecastWords.toCompleteLine(forecast(toComplete: t)) == "To complete: about $60 to $100")
    }

    @Test func aClosedEpicSaysItsFirstForecastAgainstWhenItLanded() {
        let kept = DaemonAPI.LineageForecastKept(at: days(-6), p50: days(-4), p85: days(-3), windowDays: 14, share: 0.06, open: 6)
        let f = forecast(noForecast: "no open children", kept: kept)
        #expect(ForecastWords.keptLine(f, landed: days(-3.5), timeZone: utc, locale: gb)
            == "Forecast at its start: by Fri 6 Nov (85%: by Sat 7 Nov); landed Sat 7 Nov, within the 85%")
        #expect(ForecastWords.keptLine(f, landed: days(-1), timeZone: utc, locale: gb)
            == "Forecast at its start: by Fri 6 Nov (85%: by Sat 7 Nov); landed Mon 9 Nov, after the 85%")
        #expect(ForecastWords.keptLine(f, landed: nil) == nil)
        #expect(ForecastWords.keptLine(forecast(), landed: now) == nil)
        #expect(ForecastWords.keptHelp(f, timeZone: utc, locale: gb) == "Made Wed 4 Nov for its 6 open children then, at the last 14 days' pace.")
    }
}
