import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// The day's total, and the questions the boundary raises. Every date is a parameter,
/// so midnight is something a test walks past rather than waits for.
@Suite("What the day cost")
struct SpendLedgerTests {
    private func temporary() -> (SpendLedger, StoreLocations) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsSpendTests-\(UUID().uuidString)", isDirectory: true)
        let locations = StoreLocations(root: root)
        return (SpendLedger(locations: locations), locations)
    }

    private func day(_ text: String) -> Date {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        f.timeZone = TimeZone.current
        return f.date(from: text)!
    }

    private func usd(_ amount: Decimal) -> Cost { Cost(amount: amount, currency: "USD") }

    @Test("banking on one day and reading on the next returns nothing")
    func theDayRollsOverByItself() {
        let (ledger, _) = temporary()
        ledger.add(usd(4), on: day("2026-09-19 14:00"))
        #expect(ledger.total(on: day("2026-09-19 23:59")) == ["USD": 4])
        #expect(ledger.total(on: day("2026-09-20 00:01")).isEmpty,
                "a new day is a key that is not there yet, and no timer resets anything")
    }

    @Test("two currencies on the same day stay apart and are never summed")
    func currenciesAreNeverAdded() {
        let (ledger, _) = temporary()
        let when = day("2026-09-19 10:00")
        ledger.add(usd(12.34), on: when)
        ledger.add(Cost(amount: 0.81, currency: "GBP"), on: when)
        #expect(ledger.total(on: when) == ["USD": 12.34, "GBP": 0.81])
    }

    @Test("a turn banked after midnight counts against the day it ended in")
    func aSpendBelongsToTheDayItsTurnEnded() {
        let (ledger, _) = temporary()
        ledger.add(usd(1), on: day("2026-09-19 23:59"))
        ledger.add(usd(2), on: day("2026-09-20 00:01"))
        #expect(ledger.total(on: day("2026-09-19 12:00")) == ["USD": 1])
        #expect(ledger.total(on: day("2026-09-20 12:00")) == ["USD": 2],
                "an agent running across midnight spends into the new day")
    }

    @Test("the day's total survives a restart")
    func aSecondLedgerOnTheSameRootSeesTheSameDay() {
        let (ledger, locations) = temporary()
        let when = day("2026-09-19 09:00")
        ledger.add(usd(3.5), on: when)
        // A new daemon, the same root.
        let afterRestart = SpendLedger(locations: locations)
        #expect(afterRestart.total(on: when) == ["USD": 3.5],
                "the money was counted, not forgotten")
    }

    @Test("pruning keeps the last seven days and drops the eighth")
    func onlyEnoughDaysToAnswerTheBoundaryQuestions() {
        let (ledger, locations) = temporary()
        for offset in 0..<10 {
            let when = Calendar.current.date(byAdding: .day, value: offset,
                                             to: day("2026-09-01 12:00"))!
            ledger.add(usd(1), on: when)
        }
        let data = try! Data(contentsOf: locations.spend)
        let contents = try! StoreCoding.decoder.decode(SpendLedger.Contents.self, from: data)
        #expect(contents.days.count == SpendLedger.daysKept)
        #expect(contents.days["2026-09-10"] != nil, "the day just written is kept")
        #expect(contents.days["2026-09-01"] == nil, "the eighth day back is gone")
        #expect(contents.days["2026-09-04"] != nil, "the seventh day back is kept")
    }

    @Test("a missing file reads as an empty ledger")
    func nothingWrittenYetIsZero() {
        let (ledger, _) = temporary()
        #expect(ledger.total(on: Date()).isEmpty)
    }

    @Test("an unreadable file reads as empty rather than throwing")
    func adaemonThatCannotReadItsLedgerStillWorks() throws {
        let (ledger, locations) = temporary()
        try FileManager.default.createDirectory(at: locations.root, withIntermediateDirectories: true)
        try Data("this is not JSON".utf8).write(to: locations.spend)
        #expect(ledger.total(on: Date()).isEmpty)
        // And it can still bank, which is the part that matters: under-counting today
        // is bad, refusing to work because of it is worse.
        ledger.add(usd(1), on: day("2026-09-19 12:00"))
        #expect(ledger.total(on: day("2026-09-19 12:00")) == ["USD": 1])
    }

    @Test("a day stamp is the machine's local calendar day")
    func theStampFollowsTheMachinesOwnDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Pacific/Auckland")!
        let noonInLondon = ISO8601DateFormatter().date(from: "2026-09-19T12:00:00Z")!
        // Midday UTC is already the twentieth in Auckland. The day is the machine's,
        // not UTC's, and that is what the limit is measured against.
        #expect(SpendLedger.stamp(for: noonInLondon, calendar: calendar) == "2026-09-20")

        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        #expect(SpendLedger.stamp(for: noonInLondon, calendar: utc) == "2026-09-19")
    }

    @Test("a clock change makes a short or long day, and it is still one day")
    func aDayThatMovedIsStillOneDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        // The 2026 spring-forward: 01:00 becomes 02:00 on 29 March. Twenty-three
        // hours, one stamp.
        let early = ISO8601DateFormatter().date(from: "2026-03-29T00:30:00Z")!
        let late = ISO8601DateFormatter().date(from: "2026-03-29T22:30:00Z")!
        #expect(SpendLedger.stamp(for: early, calendar: calendar)
                == SpendLedger.stamp(for: late, calendar: calendar))
    }
}
