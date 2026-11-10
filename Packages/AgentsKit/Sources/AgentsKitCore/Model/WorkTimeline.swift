import Foundation

// MARK: - The wire (#4172)

public extension DaemonAPI {
    /// `work/timeline` (#4172): the epics of a project (its id) whose work overlaps `from` to `to`.
    struct WorkTimelineRequest: Codable, Sendable, Hashable {
        public var project: String
        public var from: Date
        public var to: Date

        public init(project: String, from: Date, to: Date) {
            self.project = project
            self.from = from
            self.to = to
        }
    }

    /// The epics of the window, each with its children, its lines and its forecast (M10), and the
    /// releases published in it. `timeZone` is the working clock's; `backtest` how past forecasts did.
    struct WorkTimeline: Codable, Sendable, Hashable {
        public var epics: [WorkTimelineEpic]
        public var releases: [WorkTimelineRelease]
        public var timeZone: String?
        public var backtest: WorkTimelineBacktest?
        public var errors: [String]?

        public init(epics: [WorkTimelineEpic] = [], releases: [WorkTimelineRelease] = [], timeZone: String? = nil,
                    backtest: WorkTimelineBacktest? = nil, errors: [String]? = nil) {
            self.epics = epics
            self.releases = releases
            self.timeZone = timeZone
            self.backtest = backtest
            self.errors = errors
        }
    }

    /// How the forecast did on the epics of the last 30 days: `error` is the median factor it was
    /// off by (2.2 says ×2.2); `width` already widens each band.
    struct WorkTimelineBacktest: Codable, Sendable, Hashable {
        public var error: Double
        public var width: Double
        public var cuts: Int
        public var holds: Int
        public var epics: Int
        public var at: Date

        public init(error: Double, width: Double, cuts: Int, holds: Int, epics: Int, at: Date) {
            self.error = error
            self.width = width
            self.cuts = cuts
            self.holds = holds
            self.epics = epics
            self.at = at
        }
    }

    /// A child of an epic: when it started (absent while nothing started it), closed, or is
    /// forecast to close; `waitsForPerson` when it is labelled for the person, so not forecast.
    struct WorkTimelineChild: Codable, Sendable, Hashable {
        public var item: ForgeItem
        public var stateReason: String?
        public var createdAt: Date
        public var startedAt: Date?
        public var closedAt: Date?
        public var waitsForPerson: Bool?
        public var forecastAt: Date?

        public init(item: ForgeItem, stateReason: String? = nil, createdAt: Date, startedAt: Date? = nil,
                    closedAt: Date? = nil, waitsForPerson: Bool? = nil, forecastAt: Date? = nil) {
            self.item = item
            self.stateReason = stateReason
            self.createdAt = createdAt
            self.startedAt = startedAt
            self.closedAt = closedAt
            self.waitsForPerson = waitsForPerson
            self.forecastAt = forecastAt
        }
    }

    /// An epic: its children, its lines (the first first) and, while one is open, its forecast.
    struct WorkTimelineEpic: Codable, Sendable, Hashable {
        public var item: ForgeItem
        public var stateReason: String?
        public var createdAt: Date
        public var closedAt: Date?
        public var children: [WorkTimelineChild]
        public var segments: [WorkTimelineSegment]
        public var forecast: WorkTimelineForecast?

        public init(item: ForgeItem, stateReason: String? = nil, createdAt: Date, closedAt: Date? = nil,
                    children: [WorkTimelineChild] = [], segments: [WorkTimelineSegment] = [],
                    forecast: WorkTimelineForecast? = nil) {
            self.item = item
            self.stateReason = stateReason
            self.createdAt = createdAt
            self.closedAt = closedAt
            self.children = children
            self.segments = segments
            self.forecast = forecast
        }
    }

    /// An open epic's close: `mid` the P50, `low` to `high` the band that holds it 8 times in 10;
    /// `waits` when children wait for the person, so the line does not join.
    struct WorkTimelineForecast: Codable, Sendable, Hashable {
        public var low: Date
        public var mid: Date
        public var high: Date
        public var waits: Bool?

        public init(low: Date, mid: Date, high: Date, waits: Bool? = nil) {
            self.low = low
            self.mid = mid
            self.high = high
            self.waits = waits
        }
    }

    struct WorkTimelineRelease: Codable, Sendable, Hashable {
        public var tag: String
        public var at: Date
        public var repo: String
        public var url: String?

        public init(tag: String, at: Date, repo: String, url: String? = nil) {
            self.tag = tag
            self.at = at
            self.repo = repo
            self.url = url
        }
    }

    /// A line of an epic: from its first child's start to its last child's close.
    struct WorkTimelineSegment: Codable, Sendable, Hashable {
        public var startedAt: Date?
        public var closedAt: Date?

        public init(startedAt: Date? = nil, closedAt: Date? = nil) {
            self.startedAt = startedAt
            self.closedAt = closedAt
        }
    }
}

public extension DaemonAPI.Method {
    /// `WorkTimelineRequest` → `WorkTimeline` (#4172).
    static let workTimeline = "work/timeline"
}

// MARK: - The layout (#4173, specs/time-stream/wireframe.md sections 2, 7, 9 and 12)

/// Work ▸ Timeline (#4173): the epics as lines that leave the releases line when their first child
/// starts and join it when their last child closes, on a linear time axis. This is the part both
/// clients share (the web page gets a TypeScript copy later): the range, the lines, their lanes, the
/// marks and the words. The Mac draws it with a `Canvas`.
public enum WorkTimeline {
    /// The toolbar's range. 1 Day and 2 Days keep Now in the centre; Week puts it at three quarters,
    /// as the forecast reaches only about 1.5 days ahead (Alex, 2026-11-09, #4173).
    public enum Range: String, CaseIterable, Identifiable, Sendable, Hashable {
        case day, twoDays, week

        public var id: Self { self }

        public var title: String {
            switch self {
            case .day: "1 Day"
            case .twoDays: "2 Days"
            case .week: "Week"
            }
        }

        public var span: TimeInterval {
            switch self {
            case .day: 86_400
            case .twoDays: 2 * 86_400
            case .week: 7 * 86_400
            }
        }

        /// The range in words, after "in": "6 epics in these 2 days".
        public var these: String {
            switch self {
            case .day: "these 24 hours"
            case .twoDays: "these 2 days"
            case .week: "these 7 days"
            }
        }

        /// Where Now is, from the left edge, as a share of the width.
        public var nowAt: Double { self == .week ? 0.75 : 0.5 }

        /// The window seen when the page opens or Now is clicked.
        public func window(now: Date) -> DateInterval {
            let from = now.addingTimeInterval(-span * nowAt)
            return DateInterval(start: from, duration: span)
        }

        /// A pinch steps the range: apart is a shorter one, together a longer one.
        public func zoomed(in zoomIn: Bool) -> Range {
            let all = Self.allCases
            let i = all.firstIndex(of: self)! + (zoomIn ? -1 : 1)
            return all[min(max(i, 0), all.count - 1)]
        }
    }

    /// A time axis: `interval` across `width` points.
    public struct Axis: Sendable, Hashable {
        public var interval: DateInterval
        public var width: Double

        public init(interval: DateInterval, width: Double) {
            self.interval = interval
            self.width = width
        }

        public func x(_ date: Date) -> Double {
            interval.duration <= 0 ? 0 : date.timeIntervalSince(interval.start) / interval.duration * width
        }

        public func date(_ x: Double) -> Date {
            interval.start.addingTimeInterval(width <= 0 ? 0 : x / width * interval.duration)
        }

        /// The hour ticks for a range seen across the width: every 3 hours at 1 Day, 6 at 2 Days,
        /// 24 at Week, on the hour.
        public func ticks(seen span: TimeInterval, calendar: Calendar = .current) -> [Date] {
            let hours = span <= 86_400 * 1.5 ? 3 : span <= 86_400 * 3 ? 6 : 24
            // Each hour on the clock, so a tick stays on the hour across a change of summer time.
            var hour = calendar.dateInterval(of: .hour, for: interval.start)?.start ?? interval.start
            var out: [Date] = []
            while hour <= interval.end {
                if hour >= interval.start, calendar.component(.hour, from: hour) % hours == 0 { out.append(hour) }
                hour = calendar.date(byAdding: .hour, value: 1, to: hour) ?? interval.end.addingTimeInterval(1)
            }
            return out
        }
    }

    /// How an epic's line ends.
    public enum End: Sendable, Hashable {
        /// Its last child closed: it joins the releases line.
        case joined
        /// Closed as not planned: it ends in ✕ and never joins.
        case dropped
        /// Forecast: a dashed line to a hollow ring on the releases line.
        case forecast
        /// Children wait for the person: it stops at a pill and does not join.
        case waits(Int)
        /// Open, with nothing to forecast: it stops at Now.
        case open
    }

    /// A child's dot on its line.
    public struct Dot: Sendable, Hashable, Identifiable {
        public var ref: String
        public var number: String
        public var title: String
        public var at: Date
        /// Closed: filled. Forecast: hollow.
        public var closed: Bool
        public var notPlanned: Bool

        public var id: String { ref }
    }

    /// One line: a segment of an epic.
    public struct Line: Sendable, Hashable, Identifiable {
        public var epic: DaemonAPI.LineageNode
        public var segment: Int
        public var title: String
        public var number: String
        public var feature: String?
        /// The epic's children closed, and all of them.
        public var done: Int
        public var total: Int
        public var start: Date
        /// The join, the forecast join, the pill, or Now.
        public var end: Date
        public var how: End
        public var band: DateInterval?
        public var dots: [Dot]
        /// Children working now: a ring at Now on the line.
        public var working: Int
        /// The lane: 1, 2, … above the releases line, −1, −2, … below.
        public var lane: Int = 0

        public var id: String { "\(epic.ref)/\(segment)" }

        /// The label: the name, then `#n · 6 of 8`; a short one cuts the name with "…".
        public var label: String { "\(title)  \(figures)" }
        public var figures: String { "\(number) · \(done) of \(total)" }

        /// Whether the line runs past `date` (it has not ended by then).
        public var open: Bool {
            switch how {
            case .forecast, .waits, .open: true
            case .joined, .dropped: false
            }
        }
    }

    /// The lines of a timeline, past and forecast, as section 7 says: one per segment, an epic with
    /// no children not drawn, a line that has not started not drawn unless it is forecast.
    /// `forecast` off draws the past only: an open line stops at Now.
    public static func lines(_ timeline: DaemonAPI.WorkTimeline, now: Date, forecast: Bool = true) -> [Line] {
        timeline.epics.flatMap { epic -> [Line] in
            guard !epic.children.isEmpty else { return [] }
            let total = epic.children.count
            let done = epic.children.filter { $0.closedAt != nil }.count
            let last = epic.segments.count - 1
            return epic.segments.enumerated().compactMap { i, segment -> Line? in
                let isOpen = segment.closedAt == nil && i == last
                // The children of this line: those that closed in it, and the open ones on the open line.
                let next = i < last ? epic.segments[i + 1].startedAt : nil
                let mine = epic.children.filter { child in
                    if let closed = child.closedAt {
                        let from = i == 0 ? Date.distantPast : segment.startedAt ?? .distantPast
                        let to = next ?? .distantFuture
                        return closed >= from && closed < to
                    }
                    return isOpen
                }
                let forecastStarts = mine.compactMap(\.forecastAt).min()
                guard let start = segment.startedAt ?? (forecast ? forecastStarts : nil) else { return nil }
                var how = End.joined
                var end = segment.closedAt ?? now
                var band: DateInterval?
                let waiting = mine.filter { $0.closedAt == nil && $0.waitsForPerson == true }.count
                if isOpen {
                    if waiting > 0 {
                        how = .waits(waiting)
                        if forecast, let f = epic.forecast { end = max(f.mid, now) }
                    } else if forecast, let f = epic.forecast {
                        how = .forecast
                        end = max(f.mid, now)
                        band = DateInterval(start: min(f.low, f.high), end: max(f.low, f.high))
                    } else {
                        how = .open
                    }
                } else if epic.stateReason == "not_planned" || (epic.closedAt != nil && epic.item.state == "closed"
                                                                 && mine.allSatisfy { $0.stateReason == "not_planned" }) {
                    how = .dropped
                }
                end = max(end, start)
                let dots = mine.compactMap { child -> Dot? in
                    let number = WorkList.shortRef(child.item.node.ref)
                    if let closed = child.closedAt {
                        // A child closed before its line forked sits at the fork (section 12, item 7).
                        return Dot(ref: child.item.node.ref, number: number, title: child.item.title,
                                   at: min(max(closed, start), end), closed: true,
                                   notPlanned: child.stateReason == "not_planned")
                    }
                    guard forecast, child.waitsForPerson != true, let at = child.forecastAt else { return nil }
                    return Dot(ref: child.item.node.ref, number: number, title: child.item.title,
                               at: min(max(at, max(start, now)), end), closed: false, notPlanned: false)
                }
                let working = isOpen ? mine.filter { $0.closedAt == nil && $0.startedAt != nil && $0.waitsForPerson != true }.count : 0
                return Line(epic: epic.item.node, segment: i, title: epic.item.title,
                            number: WorkList.shortRef(epic.item.node.ref), feature: epic.item.feature,
                            done: done, total: total, start: start, end: end, how: how, band: band,
                            dots: dots.sorted { $0.at < $1.at }, working: working)
            }
        }
    }

    /// Only the lines that overlap the window (Alex, 2026-11-08). A line that waits for the person
    /// has no end, so it is drawn while it is open.
    public static func overlapping(_ lines: [Line], _ window: DateInterval) -> [Line] {
        lines.filter { line in
            let end: Date
            if case .waits = line.how { end = .distantFuture } else { end = max(line.end, line.band?.end ?? line.end) }
            return line.start <= window.end && end >= window.start
        }
    }

    /// The fork's and the join's width, in points: 12 pt and 4 pt for each lane (section 12, item 2).
    public static func riser(_ lane: Int) -> Double { 12 + 4 * Double(abs(lane)) }

    /// The lanes nearest the releases line first, above and below in turn: 1, −1, 2, −2, …
    static func lane(_ i: Int) -> Int { i % 2 == 0 ? i / 2 + 1 : -(i / 2 + 1) }

    /// Put each line on the free lane nearest the releases line, sorted by start (section 9). A lane
    /// is free when its last line has joined and that line's label has ended: `labelWidth` measures
    /// a label in points, and `gap` keeps a little air after each.
    public static func layout(_ lines: [Line], axis: Axis, labelWidth: (Line) -> Double, gap: Double = 8) -> [Line] {
        var busy: [Int: Double] = [:]
        return lines.sorted { ($0.start, $0.id) < ($1.start, $1.id) }.map { line in
            var placed = line
            let startX = axis.x(line.start)
            var i = 0
            while let until = busy[lane(i)], until > startX { i += 1 }
            placed.lane = lane(i)
            let labelEnd = startX + riser(placed.lane) + labelWidth(line)
            let endX = axis.x(line.end)
            let bandEnd = line.band.map { axis.x($0.end) } ?? endX
            let ends: Double
            if case .waits = line.how { ends = .infinity } else { ends = max(endX, bandEnd) }
            busy[placed.lane] = max(labelEnd, ends) + gap
            return placed
        }
    }

    /// Where a dot is drawn: at its time, held to the stretch of the line that is on its lane, so
    /// no dot is on the fork's or the join's curve, off the line (Alex, 2026-11-10).
    public static func dotX(_ dot: Dot, on line: Line, axis: Axis) -> Double {
        let r = riser(line.lane)
        let sx = axis.x(line.start), ex = max(axis.x(line.end), sx)
        let from = sx + r
        let to = line.how == .joined || line.how == .forecast ? max(ex - r, from) : max(ex, from)
        return min(max(axis.x(dot.at), from), to)
    }

    /// The lanes in use, above and below: the plot is as tall as the higher of the two sides.
    public static func lanes(_ lines: [Line]) -> (above: Int, below: Int) {
        (lines.map(\.lane).filter { $0 > 0 }.max() ?? 0, -(lines.map(\.lane).filter { $0 < 0 }.min() ?? 0))
    }

    /// A join on the releases line: one ring, or one ring with a count for joins within 6 pt of
    /// each other (section 12, item 5).
    public struct Join: Sendable, Hashable {
        public var at: Date
        public var lines: [String]
        public var forecast: Bool
    }

    public static func joins(_ lines: [Line], axis: Axis, within: Double = 6) -> [Join] {
        let rings = lines.compactMap { line -> Join? in
            switch line.how {
            case .joined: Join(at: line.end, lines: [line.id], forecast: false)
            case .forecast: Join(at: line.end, lines: [line.id], forecast: true)
            default: nil
            }
        }.sorted { $0.at < $1.at }
        var out: [Join] = []
        for ring in rings {
            if let last = out.last, last.forecast == ring.forecast, axis.x(ring.at) - axis.x(last.at) < within {
                out[out.count - 1].lines += ring.lines
            } else {
                out.append(ring)
            }
        }
        return out
    }

    /// How far a line's label may run from `x`: the whole line, to its end (Alex, 2026-11-10). It
    /// runs past Now and over its band, on its halo; a pill where the line waits is after its end.
    public static func labelRoom(_ line: Line, from x: Double, axis: Axis) -> Double {
        axis.x(line.end) - x
    }

    /// What a label says: the name, whole or cut short with "…", or "" for none; then the figures.
    public struct Words: Sendable, Hashable {
        public var title: String
        public var figures: String
        public var text: String { title.isEmpty ? figures : "\(title)  \(figures)" }
    }

    /// The label that fits `room`: the whole one, then the name cut short with "…" before the
    /// figures, then the figures alone, then nothing.
    public static func label(_ line: Line, room: Double, measure: (String) -> Double) -> Words? {
        if measure(line.label) <= room { return Words(title: line.title, figures: line.figures) }
        let title = Array(line.title)
        var best: String?
        var low = 1, high = title.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let cut = String(title[..<mid]).trimmingCharacters(in: .whitespaces)
            if !cut.isEmpty, measure("\(cut)…  \(line.figures)") <= room {
                best = cut + "…"
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        if let best { return Words(title: best, figures: line.figures) }
        if measure(line.figures) <= room { return Words(title: "", figures: line.figures) }
        return nil
    }

    // MARK: - Colours

    /// A feature's colour, as an index into the client's palette of system colours, the same
    /// every time for the same name. No feature takes the last one (grey).
    public static func colour(_ feature: String?, of count: Int) -> Int {
        guard let feature, !feature.isEmpty, count > 1 else { return max(count - 1, 0) }
        var hash: UInt32 = 2_166_136_261
        for byte in feature.lowercased().utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        return Int(hash % UInt32(count - 1))
    }

    // MARK: - Hit testing

    /// What the pointer is on: a dot within 10 pt, else a line within 8 pt, else a release or a join.
    public enum Hit: Sendable, Hashable {
        case dot(Line, Dot)
        case line(Line)
        case join(Join)
        case release(DaemonAPI.WorkTimelineRelease)
    }

    /// `y` is the lane's centre, from the releases line; `laneHeight` the points between lanes.
    public static func hit(_ point: (x: Double, y: Double), lines: [Line], releases: [DaemonAPI.WorkTimelineRelease],
                           axis: Axis, trunk: Double, laneHeight: Double) -> Hit? {
        func y(_ lane: Int) -> Double { trunk - Double(lane) * laneHeight }
        var best: (Double, Hit)?
        for line in lines {
            for dot in line.dots {
                let d = hypot(dotX(dot, on: line, axis: axis) - point.x, y(line.lane) - point.y)
                if d <= 10, d < best?.0 ?? .infinity { best = (d, .dot(line, dot)) }
            }
        }
        if let best { return best.1 }
        for join in joins(lines, axis: axis) {
            let d = hypot(axis.x(join.at) - point.x, trunk - point.y)
            if d <= 10, d < best?.0 ?? .infinity { best = (d, .join(join)) }
        }
        for release in releases {
            let d = hypot(axis.x(release.at) - point.x, trunk - point.y)
            if d <= 10, d < best?.0 ?? .infinity { best = (d, .release(release)) }
        }
        if let best { return best.1 }
        for line in lines {
            let from = axis.x(line.start) + riser(line.lane)
            let to = line.how == .joined || line.how == .forecast ? axis.x(line.end) - riser(line.lane) : axis.x(line.end)
            let dy = abs(y(line.lane) - point.y)
            if dy <= 8, point.x >= from - 8, point.x <= max(from, to) + 8, dy < best?.0 ?? .infinity {
                best = (dy, .line(line))
            }
        }
        return best?.1
    }

    // MARK: - Words

    static func time(_ date: Date, now: Date, calendar: Calendar) -> String {
        let style = Date.FormatStyle(timeZone: calendar.timeZone).hour().minute()
        if calendar.isDate(date, inSameDayAs: now) { return date.formatted(style) }
        return date.formatted(Date.FormatStyle(timeZone: calendar.timeZone).weekday(.abbreviated).hour().minute())
    }

    /// "3 wait for you": the pill where a line stops for the person.
    public static func waitWords(_ count: Int) -> String { "\(count) wait\(count == 1 ? "s" : "") for you" }

    /// "Past forecasts were off by ×2.2".
    public static func errorWords(_ backtest: DaemonAPI.WorkTimelineBacktest) -> String {
        "Past forecasts were off by ×\(backtest.error.formatted(.number.precision(.fractionLength(1))))"
    }

    /// The hover card is a mini row (Work look, milestones.md note 33): a glyph, the title, and
    /// this second line. On a child's dot: "#4301 · closed 2 h ago", "#4301 · closes about 5:00 PM".
    public static func dotLine(_ dot: Dot, now: Date, calendar: Calendar = .current) -> String {
        let state = dot.closed
            ? "\(dot.notPlanned ? "closed as not planned" : "closed") \(agoWords(dot.at, now: now))"
            : "closes about \(time(dot.at, now: now, calendar: calendar))"
        return "\(dot.number) · \(state)"
    }

    /// On an epic's line or its join: "#4250 · 11 of 16 · closes about 5:00 PM · 3:00 PM–9:00 PM, 8 in 10".
    public static func lineLine(_ line: Line, now: Date, calendar: Calendar = .current) -> String {
        var out = [line.figures]
        switch line.how {
        case .joined: out.append("closed \(agoWords(line.end, now: now))")
        case .dropped: out.append("closed as not planned")
        case .forecast:
            out.append("closes about \(time(line.end, now: now, calendar: calendar))")
            if let band = line.band {
                out.append("\(time(band.start, now: now, calendar: calendar))–\(time(band.end, now: now, calendar: calendar)), 8 in 10")
            }
        case .waits(let n): out.append(waitWords(n))
        case .open: out.append("open")
        }
        return out.joined(separator: " · ")
    }

    /// On a release's pill: "alexec/Agents · released 3 h ago".
    public static func releaseLine(_ release: DaemonAPI.WorkTimelineRelease, now: Date) -> String {
        "\(release.repo) · released \(agoWords(release.at, now: now))"
    }

    /// "2 h ago", or "just now".
    static func agoWords(_ date: Date, now: Date) -> String {
        let age = WorkLook.ageWords(now.timeIntervalSince(date))
        return age == "now" ? "just now" : "\(age) ago"
    }

    /// The title line above the plot (note 32): "Agents · 6 epics in these 2 days".
    public static func titleWords(project: String, epics: Int, range: Range) -> String {
        let count = "\(epics) epic\(epics == 1 ? "" : "s") in \(range.these)"
        return project.isEmpty ? count : "\(project) · \(count)"
    }

    /// The epics with a line in `window`, each once.
    public static func epicCount(_ lines: [Line], in window: DateInterval) -> Int {
        Set(overlapping(lines, window).map(\.epic.ref)).count
    }

    /// When the last line before `date` joined, for the empty card (S11); nil when the read has none.
    public static func lastJoined(_ timeline: DaemonAPI.WorkTimeline, before date: Date) -> Date? {
        timeline.epics.flatMap(\.segments).compactMap(\.closedAt).filter { $0 < date }.max()
    }

    /// The empty card (S11): "No epic in these 2 days", and "The last one joined 4 d ago." when known.
    public static func noEpicsWords(_ range: Range) -> String { "No epic in \(range.these)" }

    public static func lastJoinedWords(_ date: Date, now: Date) -> String {
        "The last one joined \(agoWords(date, now: now))."
    }

    /// What VoiceOver reads, a row per line in time order (section 5): "Azure DevOps, 3 of 7 done,
    /// closes about 6:00 PM".
    public static func spoken(_ lines: [Line], now: Date, calendar: Calendar = .current) -> [(line: Line, words: String)] {
        lines.sorted { ($0.start, $0.id) < ($1.start, $1.id) }.map { line in
            let end = switch line.how {
            case .joined: "closed \(time(line.end, now: now, calendar: calendar))"
            case .dropped: "closed as not planned"
            case .forecast: "closes about \(time(line.end, now: now, calendar: calendar))"
            case .waits(let n): waitWords(n)
            case .open: "open"
            }
            return (line, "\(line.title), \(line.done) of \(line.total) done, \(end)")
        }
    }

    /// Several machines' timelines of one project as one: each epic and release once.
    public static func merge(_ timelines: [DaemonAPI.WorkTimeline]) -> DaemonAPI.WorkTimeline {
        var out = DaemonAPI.WorkTimeline()
        var epics = Set<String>(), releases = Set<String>()
        for t in timelines {
            out.epics += t.epics.filter { epics.insert($0.item.node.ref).inserted }
            out.releases += t.releases.filter { releases.insert("\($0.repo)@\($0.tag)").inserted }
            out.timeZone = out.timeZone ?? t.timeZone
            out.backtest = out.backtest ?? t.backtest
            if let e = t.errors, !e.isEmpty { out.errors = (out.errors ?? []) + e.filter { !(out.errors ?? []).contains($0) } }
        }
        out.releases.sort { $0.at < $1.at }
        return out
    }

    public static let showTheWeek = "Show the week"
    /// S12: no project to draw.
    public static let noProject = "No project to draw"
    public static let noProjectLine = "Timeline shows a project’s epics. Add a folder to a project to see them."
    public static let noMachine = "No machine draws the timeline yet. Update Agents on a machine to see it."
}
