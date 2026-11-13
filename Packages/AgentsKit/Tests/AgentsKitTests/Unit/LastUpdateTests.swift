import Foundation
import Testing
@testable import AgentsKitCore

/// The "Last update" line (#5141), as `Web/test/lastUpdate.test.mjs` says it for the page.
@Suite("Last update")
struct LastUpdateTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        return calendar
    }()
    private let locale = Locale(identifier: "en_GB")
    /// 13 Nov 2026, 15:30 in London.
    private let now = Date(timeIntervalSince1970: 1_794_583_800)

    private func line(_ secondsAgo: TimeInterval) -> String {
        LastUpdate.line(since: now.addingTimeInterval(-secondsAgo), now: now, calendar: calendar, locale: locale)
    }

    @Test func theWords() {
        #expect(line(0) == "Last update just now")
        #expect(line(59) == "Last update just now")
        #expect(line(-30) == "Last update just now", "a read ahead of this clock")
        #expect(line(60) == "Last update 1 min ago")
        #expect(line(5 * 60 + 20) == "Last update 5 min ago")
        #expect(line(59 * 60) == "Last update 59 min ago")
        #expect(line(3600) == "Last update 1 h ago")
        #expect(line(2 * 3600 + 1) == "Last update 2 h ago")
        #expect(line(23 * 3600 + 59 * 60) == "Last update 23 h ago")
        #expect(line(24 * 3600) == "Last update yesterday")
        #expect(line(10 * 24 * 3600) == "Last update 3 Nov")
        #expect(line(400 * 24 * 3600) == "Last update 9 Oct 2025")
    }

    @Test func spoken() {
        let say = { (s: TimeInterval) in
            LastUpdate.spoken(since: now.addingTimeInterval(-s), now: now, calendar: calendar, locale: locale)
        }
        #expect(say(5) == "Last update just now")
        #expect(say(60) == "Last update 1 minute ago")
        #expect(say(5 * 60) == "Last update 5 minutes ago")
        #expect(say(3600) == "Last update 1 hour ago")
        #expect(say(2 * 3600) == "Last update 2 hours ago")
        #expect(say(24 * 3600) == "Last update yesterday")
    }

    @Test func ticksEveryTenSecondsThenEachMinute() {
        let read = now
        #expect(LastUpdate.nextChange(since: read, after: read) == read.addingTimeInterval(10))
        #expect(LastUpdate.nextChange(since: read, after: read.addingTimeInterval(15)) == read.addingTimeInterval(20))
        #expect(LastUpdate.nextChange(since: read, after: read.addingTimeInterval(55)) == read.addingTimeInterval(60))
        #expect(LastUpdate.nextChange(since: read, after: read.addingTimeInterval(60)) == read.addingTimeInterval(120))
        #expect(LastUpdate.nextChange(since: read, after: read.addingTimeInterval(130)) == read.addingTimeInterval(180))
    }
}

extension LastUpdateTests {
    @Test func aBannerSaysItAfterItsWords() {
        let read = now.addingTimeInterval(-5 * 60)
        #expect(LastUpdate.banner("Can't reach your Mac.", read: read, now: now) == "Can't reach your Mac. Last update 5 min ago")
        #expect(LastUpdate.banner("Not connected to your Mac yet", read: nil, now: now) == "Not connected to your Mac yet")
    }
}
