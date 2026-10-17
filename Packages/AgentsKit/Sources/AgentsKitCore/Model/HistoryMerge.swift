import Foundation

/// Every host's history as one, in the viewer's calendar (#1267), so the charts on Cost,
/// Tokens and Time count a server's work in the day it was in here. A host stamps its
/// hours and days in its own zone (`timeZone`); a server in UTC and a Mac in PDT do not
/// agree on what day 02:41 UTC is.
///
/// Each host's hours move into the viewer's hours exactly. Its days are made again from
/// those hours, which are whole from the oldest one kept onwards (all of them, while
/// none has been dropped). A day older than that has only its day total, and goes in the
/// viewer's day that holds its middle.
enum HistoryMerge {
    struct Tiers<Bucket> {
        var hours: [String: [String: Bucket]]
        var days: [String: [String: Bucket]]
        var now: String
        var timeZone: String?
    }

    static func merged<Bucket>(_ hosts: [Tiers<Bucket>], calendar: Calendar, empty: Bucket,
                               add: (inout Bucket, Bucket) -> Void) -> Tiers<Bucket> {
        var out = Tiers<Bucket>(hours: [:], days: [:], now: "", timeZone: calendar.timeZone.identifier)
        func fold(_ runtimes: [String: Bucket], into tier: inout [String: [String: Bucket]], at key: String) {
            for (runtime, bucket) in runtimes {
                add(&tier[key, default: [:]][runtime, default: empty], bucket)
            }
        }
        for host in hosts {
            var hostCalendar = calendar
            if let id = host.timeZone, let zone = TimeZone(identifier: id) { hostCalendar.timeZone = zone }
            guard hostCalendar.timeZone.identifier != calendar.timeZone.identifier else {
                for (key, runtimes) in host.hours { fold(runtimes, into: &out.hours, at: key) }
                for (key, runtimes) in host.days { fold(runtimes, into: &out.days, at: key) }
                out.now = max(out.now, host.now)
                continue
            }
            // The first of the host's days that is whole in its hours: the day its oldest
            // kept hour is in when none were ever dropped, else the day after.
            let whole = host.hours.keys.min().map { oldest in
                let day = String(oldest.prefix(10))
                return host.hours.count < UsageHistory.hoursKept ? day : day + "~"
            }
            for (key, runtimes) in host.hours {
                guard let start = UsageChart.date(key, calendar: hostCalendar) else { continue }
                let hour = UsageHistory.hourStamp(for: start, calendar: calendar)
                fold(runtimes, into: &out.hours, at: hour)
                if let whole, String(key.prefix(10)) >= whole {
                    fold(runtimes, into: &out.days, at: String(hour.prefix(10)))
                }
            }
            for (key, runtimes) in host.days {
                if let whole, key >= whole { continue }
                guard let start = UsageChart.date(key, calendar: hostCalendar),
                      let middle = hostCalendar.date(byAdding: .hour, value: 12, to: start) else { continue }
                fold(runtimes, into: &out.days, at: UsageChart.dayStamp(middle, calendar: calendar))
            }
            if let now = UsageChart.date(host.now, calendar: hostCalendar) {
                out.now = max(out.now, UsageHistory.hourStamp(for: now, calendar: calendar))
            }
        }
        return out
    }
}

extension UsageHistory {
    /// Every host's history added up in `calendar`, the viewer's (#1267).
    public static func merged(_ histories: [UsageHistory], calendar: Calendar = .current) -> UsageHistory {
        let tiers = HistoryMerge.merged(
            histories.map { HistoryMerge.Tiers(hours: $0.hours, days: $0.days, now: $0.now, timeZone: $0.timeZone) },
            calendar: calendar, empty: UsageBucket(), add: { $0.add($1) })
        return UsageHistory(hours: tiers.hours, days: tiers.days, now: tiers.now, timeZone: tiers.timeZone)
    }
}

extension TimeHistory {
    /// Every host's time added up in `calendar`, the viewer's (#1267). The recap and the
    /// records are the first history's, the home host's: a day's most agents at once or
    /// longest clear stretch is one host's figure, and two hosts' do not add up to one.
    public static func merged(_ histories: [TimeHistory], calendar: Calendar = .current) -> TimeHistory {
        let tiers = HistoryMerge.merged(
            histories.map { HistoryMerge.Tiers(hours: $0.hours, days: $0.days, now: $0.now, timeZone: $0.timeZone) },
            calendar: calendar, empty: TimeBucket(), add: { $0.add($1) })
        return TimeHistory(hours: tiers.hours, days: tiers.days, now: tiers.now, timeZone: tiers.timeZone,
                           recap: histories.first?.recap ?? [:], records: histories.first?.records ?? TimeRecords())
    }
}
