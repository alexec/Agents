import Foundation

/// The words for an epic's forecast (#4527) on Work's epic page, from `lineage/forecast` (#4526),
/// as `Web/src/model/forecast.ts` has them on the web page: when it lands (P50, and P85 as the
/// "85%"), what it costs to complete, and, for a closed epic, the first forecast against when it
/// landed. The method is in `specs/4533-forecasting/spec.md`.
public enum ForecastWords {
    public typealias Forecast = DaemonAPI.LineageForecast

    /// The reasons that say nothing to a person on an epic's page: the page shows no line for them.
    static let silent: Set<String> = ["not an epic", "no open children"]

    /// "Likely lands by Thu 12 Nov (85%: by Fri 13 Nov), at the last 14 days' pace"; with no date,
    /// "No landing forecast: fewer than 5 closed epics"; nil when there is nothing to say.
    public static func landsLine(_ f: Forecast, timeZone: TimeZone = .current, locale: Locale = .current) -> String? {
        guard let lands = f.lands else {
            guard let why = f.noForecast, !silent.contains(why) else { return nil }
            return "No landing forecast: \(why)"
        }
        let hours = lands.p85.timeIntervalSince(f.at) < 48 * 3600
        let p50 = day(lands.p50, hours: hours, timeZone, locale), p85 = day(lands.p85, hours: hours, timeZone, locale)
        return "Likely lands by \(p50) (85%: by \(p85)), at the last \(f.windowDays) days' pace"
    }

    /// "To complete: about $60 to $140 ($80 to $190 all in)", with no "all in" when it rounds the
    /// same; nil until 3 closed children have an estimate and an actual.
    public static func toCompleteLine(_ f: Forecast) -> String? {
        guard let t = f.toComplete, !t.cost.isEmpty else { return nil }
        let parts = t.cost.sorted { $0.key < $1.key }.map { code, r in
            let words = span(r, code)
            guard let all = t.loaded?[code], span(all, code) != words else { return words }
            return words + " (\(span(all, code, about: false)) all in)"
        }
        return "To complete: \(parts.joined(separator: "; "))"
    }

    /// The assumptions, for the lines' help: what the dates count and what they leave out, and what
    /// the estimate to complete is made from.
    public static func help(_ f: Forecast) -> String? {
        var words: [String] = []
        if let l = f.lands {
            var w = "For the \(plural(l.open, "open child", "open children")) filed now, not ones still to come: "
                + "1,000 draws of the last \(f.windowDays) days' landings, hour by hour, of which an epic gets "
                + "\(percent(l.share)), the median of \(plural(l.groups, "closed epic", "closed epics"))."
            if l.stepsLeft > 1 { w += " The \(l.stepsLeft) blocked-by steps left do not move the date." }
            words.append(w)
        }
        if let t = f.toComplete, !t.cost.isEmpty {
            var w = "To complete: the open children's estimates × \(ratio(t.ratio)), as the "
                + "\(plural(t.closed, "closed child", "closed children")) cost against theirs"
            if t.leadRatio > 0 { w += ", plus \(percent(t.leadRatio)) for the lead" }
            w += "."
            if toCompleteLine(f)?.contains("all in") == true { w += " All in adds the cost no issue links to." }
            words.append(w)
        }
        return words.isEmpty ? nil : words.joined(separator: " ")
    }

    /// A closed epic's first forecast against when it landed: "Forecast at its start: by Thu 5 Nov
    /// (85%: by Fri 6 Nov); landed Thu 5 Nov, within the 85%". Nil with no kept forecast or no
    /// close date.
    public static func keptLine(_ f: Forecast, landed: Date?, timeZone: TimeZone = .current,
                                locale: Locale = .current) -> String? {
        guard let k = f.kept, let landed else { return nil }
        let hours = k.p85.timeIntervalSince(k.at) < 48 * 3600
        let d = { (date: Date) in day(date, hours: hours, timeZone, locale) }
        let held = landed <= k.p85 ? "within the 85%" : "after the 85%"
        return "Forecast at its start: by \(d(k.p50)) (85%: by \(d(k.p85))); landed \(d(landed)), \(held)"
    }

    /// The kept forecast's help: "Made Wed 4 Nov for its 6 open children then, at the last 14 days' pace."
    public static func keptHelp(_ f: Forecast, timeZone: TimeZone = .current, locale: Locale = .current) -> String? {
        guard let k = f.kept else { return nil }
        return "Made \(day(k.at, hours: false, timeZone, locale)) for its \(plural(k.open, "open child", "open children")) "
            + "then, at the last \(k.windowDays) days' pace."
    }

    /// "Thu 12 Nov", or "Thu 12 Nov, 15:00" when the forecast is for the next two days.
    static func day(_ d: Date, hours: Bool, _ timeZone: TimeZone, _ locale: Locale) -> String {
        let style = Date.FormatStyle(locale: locale, timeZone: timeZone)
        let date = d.formatted(style.weekday(.abbreviated).day().month(.abbreviated))
        return hours ? "\(date), \(d.formatted(style.hour().minute()))" : date
    }

    /// "about $60 to $140", or "about $60" when both ends round the same.
    private static func span(_ r: DaemonAPI.LineageEstimateRange, _ code: String, about: Bool = true) -> String {
        let low = EstimateWords.rough(r.p10, code), high = EstimateWords.rough(r.p90, code)
        let words = low == high ? EstimateWords.rough(r.median, code) : "\(low) to \(high)"
        return about ? "about \(words)" : words
    }

    private static func percent(_ v: Double) -> String {
        (v * 100).formatted(.number.precision(.fractionLength(0...1))) + "%"
    }

    private static func ratio(_ v: Double) -> String {
        v.formatted(.number.precision(.fractionLength(0...2)))
    }

    private static func plural(_ n: Int, _ one: String, _ many: String) -> String {
        "\(n) \(n == 1 ? one : many)"
    }
}
