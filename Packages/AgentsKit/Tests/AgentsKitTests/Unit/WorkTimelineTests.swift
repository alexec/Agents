import Foundation
import Testing
@testable import AgentsKitCore

/// Work ▸ Timeline's layout (#4173, specs/time-stream/wireframe.md sections 2, 7, 9 and 12).
@Suite("Work timeline")
struct WorkTimelineTests {
    typealias Node = DaemonAPI.LineageNode
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func h(_ hours: Double) -> Date { now.addingTimeInterval(hours * 3600) }

    static func item(_ n: Int, feature: String? = nil, state: String = "open") -> DaemonAPI.ForgeItem {
        DaemonAPI.ForgeItem(node: Node(kind: "issue", ref: "github:alexec/Agents#\(n)"), title: "Issue \(n)",
                            state: state, updatedAt: now, feature: feature)
    }

    static func child(_ n: Int, started: Double? = nil, closed: Double? = nil, forecast: Double? = nil,
                      waits: Bool = false, reason: String? = nil) -> DaemonAPI.WorkTimelineChild {
        DaemonAPI.WorkTimelineChild(item: item(n, state: closed == nil ? "open" : "closed"), stateReason: reason,
                                    createdAt: h(-100), startedAt: started.map(h), closedAt: closed.map(h),
                                    waitsForPerson: waits ? true : nil, forecastAt: forecast.map(h))
    }

    static func epic(_ n: Int, _ children: [DaemonAPI.WorkTimelineChild], segments: [(Double?, Double?)],
                     forecast: DaemonAPI.WorkTimelineForecast? = nil, feature: String? = "work",
                     reason: String? = nil) -> DaemonAPI.WorkTimelineEpic {
        DaemonAPI.WorkTimelineEpic(item: item(n, feature: feature), stateReason: reason, createdAt: h(-100),
                                   children: children,
                                   segments: segments.map { .init(startedAt: $0.0.map(h), closedAt: $0.1.map(h)) },
                                   forecast: forecast)
    }

    static let axis = WorkTimeline.Axis(interval: DateInterval(start: h(-24), end: h(24)), width: 960)

    @Test func theRangesPutNowInTheCentreAndWeekAtThreeQuarters() {
        #expect(WorkTimeline.Range.allCases.map(\.title) == ["1 Day", "2 Days", "Week"])
        let two = WorkTimeline.Range.twoDays.window(now: Self.now)
        #expect(two.start == Self.h(-24) && two.end == Self.h(24))
        let day = WorkTimeline.Range.day.window(now: Self.now)
        #expect(day.start == Self.h(-12) && day.end == Self.h(12))
        // Alex, 2026-11-09: in Week, Now sits at three quarters of the width.
        let week = WorkTimeline.Range.week.window(now: Self.now)
        #expect(week.start == Self.h(-126) && week.end == Self.h(42))
        #expect(WorkTimeline.Range.twoDays.zoomed(in: true) == .day)
        #expect(WorkTimeline.Range.day.zoomed(in: true) == .day)
        #expect(WorkTimeline.Range.twoDays.zoomed(in: false) == .week)
    }

    @Test func theAxisIsLinearTime() {
        #expect(Self.axis.x(Self.h(-24)) == 0)
        #expect(Self.axis.x(Self.now) == 480)
        #expect(Self.axis.date(960) == Self.h(24))
        let ticks = Self.axis.ticks(seen: 2 * 86_400, calendar: Calendar(identifier: .gregorian))
        #expect(ticks.count >= 8 && ticks.allSatisfy { Self.axis.interval.contains($0) })
        // A wider plot keeps the seen range's step: still every 6 hours.
        let wide = WorkTimeline.Axis(interval: DateInterval(start: Self.h(-72), end: Self.h(72)), width: 2880)
        #expect(wide.ticks(seen: 2 * 86_400, calendar: Calendar(identifier: .gregorian)).count >= 24)
        // Across the end of summer time, a day's tick is still midnight.
        var pacific = Calendar(identifier: .gregorian)
        pacific.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let fall = DateInterval(start: pacific.date(from: DateComponents(year: 2026, month: 10, day: 28))!,
                                end: pacific.date(from: DateComponents(year: 2026, month: 11, day: 5))!)
        let days = WorkTimeline.Axis(interval: fall, width: 800).ticks(seen: 7 * 86_400, calendar: pacific)
        #expect(days.count == 9 && days.allSatisfy { pacific.component(.hour, from: $0) == 0 })
    }

    @Test func anEpicWithNoChildrenIsNotDrawnAndALineIsASegment() throws {
        let timeline = DaemonAPI.WorkTimeline(epics: [
            Self.epic(1, [], segments: []),
            Self.epic(2, [Self.child(10, started: -20, closed: -18), Self.child(11, started: -6, closed: -5)],
                      segments: [(-20, -18), (-6, -5)]),
        ])
        let lines = WorkTimeline.lines(timeline, now: Self.now)
        try #require(lines.count == 2)
        #expect(lines.map(\.id) == ["github:alexec/Agents#2/0", "github:alexec/Agents#2/1"])
        #expect(lines.map(\.how) == [.joined, .joined])
        // Each child's dot is on the line it closed in.
        #expect(lines[0].dots.map(\.number) == ["#10"])
        #expect(lines[1].dots.map(\.number) == ["#11"])
        #expect(lines[1].figures == "#2 · 2 of 2")
    }

    @Test func noDotIsBeforeItsFork() {
        // Section 12, item 7: a child closed before its line forked sits at the fork.
        let timeline = DaemonAPI.WorkTimeline(epics: [
            Self.epic(3, [Self.child(12, closed: -30), Self.child(13, started: -10, closed: -2)], segments: [(-10, -2)]),
        ])
        let line = WorkTimeline.lines(timeline, now: Self.now)[0]
        #expect(line.dots.allSatisfy { $0.at >= line.start && $0.at <= line.end })
    }

    @Test func anOpenLineIsForecastWaitsOrStopsAtNow() throws {
        let forecast = DaemonAPI.WorkTimelineForecast(low: Self.h(2), mid: Self.h(5), high: Self.h(11))
        let timeline = DaemonAPI.WorkTimeline(epics: [
            Self.epic(4, [Self.child(20, started: -8, closed: -3), Self.child(21, started: -1, forecast: 3),
                          Self.child(22, forecast: 5)], segments: [(-8, nil)], forecast: forecast),
            Self.epic(5, [Self.child(23, started: -4), Self.child(24, waits: true)], segments: [(-4, nil)],
                      forecast: .init(low: Self.h(1), mid: Self.h(2), high: Self.h(3), waits: true)),
            Self.epic(6, [Self.child(25, started: -4)], segments: [(-4, nil)]),
            // Not started, but forecast: it forks at its first child's forecast.
            Self.epic(7, [Self.child(26, forecast: 6)], segments: [(nil, nil)],
                      forecast: .init(low: Self.h(5), mid: Self.h(6), high: Self.h(8))),
        ])
        let lines = WorkTimeline.lines(timeline, now: Self.now)
        try #require(lines.count == 4)
        #expect(lines.map(\.how) == [.forecast, .waits(1), .open, .forecast])
        #expect(lines[0].end == Self.h(5))
        #expect(lines[0].band == DateInterval(start: Self.h(2), end: Self.h(11)))
        #expect(lines[0].dots.map(\.closed) == [true, false, false])
        #expect(lines[0].working == 1)
        #expect(lines[2].end == Self.now)
        #expect(lines[3].start == Self.h(6))
        // Forecast off: the past only.
        let past = WorkTimeline.lines(timeline, now: Self.now, forecast: false)
        try #require(past.count == 3)
        #expect(past.map(\.how) == [.open, .waits(1), .open])
        #expect(past[0].dots.allSatisfy(\.closed) && past[0].band == nil)
    }

    @Test func aDroppedEpicEndsInACross() {
        let timeline = DaemonAPI.WorkTimeline(epics: [
            Self.epic(8, [Self.child(30, started: -5, closed: -4)], segments: [(-5, -4)], reason: "not_planned"),
        ])
        #expect(WorkTimeline.lines(timeline, now: Self.now).map(\.how) == [.dropped])
    }

    @Test func onlyTheLinesThatOverlapTheWindowAreDrawn() {
        let timeline = DaemonAPI.WorkTimeline(epics: [
            Self.epic(9, [Self.child(31, started: -60, closed: -50)], segments: [(-60, -50)]),
            Self.epic(10, [Self.child(32, started: -30, closed: -20)], segments: [(-30, -20)]),
            Self.epic(11, [Self.child(33, started: -90), Self.child(34, waits: true)], segments: [(-90, nil)],
                      forecast: .init(low: Self.h(-80), mid: Self.h(-80), high: Self.h(-80), waits: true)),
        ])
        let lines = WorkTimeline.overlapping(WorkTimeline.lines(timeline, now: Self.now), Self.axis.interval)
        // A line that waits for the person is drawn while it is open.
        #expect(lines.map(\.number) == ["#10", "#11"])
    }

    @Test func eachLineTakesTheFreeLaneNearestTheReleasesLine() {
        let timeline = DaemonAPI.WorkTimeline(epics: [
            Self.epic(12, [Self.child(40, started: -20, closed: -10)], segments: [(-20, -10)]),
            Self.epic(13, [Self.child(41, started: -18, closed: -12)], segments: [(-18, -12)]),
            Self.epic(14, [Self.child(42, started: -16, closed: -14)], segments: [(-16, -14)]),
            // Starts after #12's line and label have ended: lane 1 is free again.
            Self.epic(15, [Self.child(43, started: -5, closed: -1)], segments: [(-5, -1)]),
        ])
        let lines = WorkTimeline.layout(WorkTimeline.lines(timeline, now: Self.now), axis: Self.axis,
                                        labelWidth: { _ in 60 })
        #expect(lines.map(\.lane) == [1, -1, 2, 1])
        #expect(WorkTimeline.lanes(lines) == (above: 2, below: 1))
        // A long label keeps its lane busy after its line has joined.
        let wide = WorkTimeline.layout(WorkTimeline.lines(timeline, now: Self.now), axis: Self.axis,
                                       labelWidth: { _ in 400 })
        #expect(wide.map(\.lane) == [1, -1, 2, -2])
    }

    @Test func theRiserIsInPoints() {
        #expect(WorkTimeline.riser(1) == 16)
        #expect(WorkTimeline.riser(-9) == 48)
    }

    @Test func joinsWithinSixPointsAreOneRingWithACount() {
        let at = Self.h(5)
        let forecast = DaemonAPI.WorkTimelineForecast(low: Self.h(4), mid: at, high: Self.h(6))
        let timeline = DaemonAPI.WorkTimeline(epics: [
            Self.epic(16, [Self.child(50, started: -2, forecast: 5)], segments: [(-2, nil)], forecast: forecast),
            Self.epic(17, [Self.child(51, started: -3, forecast: 5)], segments: [(-3, nil)], forecast: forecast),
            Self.epic(18, [Self.child(52, started: -9, closed: -1)], segments: [(-9, -1)]),
        ])
        let lines = WorkTimeline.layout(WorkTimeline.lines(timeline, now: Self.now), axis: Self.axis, labelWidth: { _ in 10 })
        let joins = WorkTimeline.joins(lines, axis: Self.axis)
        #expect(joins.count == 2)
        #expect(joins.last?.lines.count == 2 && joins.last?.forecast == true)
    }

    @Test func aLabelDropsItsTitleBeforeTheNextThingOnItsLane() {
        let forecast = DaemonAPI.WorkTimelineForecast(low: Self.h(3), mid: Self.h(5), high: Self.h(8))
        let timeline = DaemonAPI.WorkTimeline(epics: [
            Self.epic(19, [Self.child(60, started: -1, forecast: 5)], segments: [(-1, nil)], forecast: forecast),
        ])
        let line = WorkTimeline.lines(timeline, now: Self.now)[0]
        let measure: (String) -> Double = { Double($0.count) * 6 }
        let x = Self.axis.x(line.start)
        // Now is 20 pt on: room for nothing.
        let room = WorkTimeline.labelRoom(line, from: x, axis: Self.axis, now: Self.now)
        #expect(room == 14)
        #expect(WorkTimeline.label(line, room: room, measure: measure) == nil)
        #expect(WorkTimeline.label(line, room: 80, measure: measure) == "#19 · 0 of 1")
        #expect(WorkTimeline.label(line, room: .infinity, measure: measure) == "Issue 19  #19 · 0 of 1")
    }

    @Test func aFeatureKeepsItsColour() {
        #expect(WorkTimeline.colour("work", of: 12) == WorkTimeline.colour("Work", of: 12))
        #expect(WorkTimeline.colour(nil, of: 12) == 11)
        #expect((0..<11).contains(WorkTimeline.colour("autonomy", of: 12)))
    }

    @Test func theHitIsTheNearestDotThenTheLine() {
        let timeline = DaemonAPI.WorkTimeline(epics: [
            Self.epic(21, [Self.child(80, started: -10, closed: -6)], segments: [(-10, -2)]),
        ], releases: [.init(tag: "v1.2.0", at: Self.h(-12), repo: "alexec/Agents")])
        let lines = WorkTimeline.layout(WorkTimeline.lines(timeline, now: Self.now), axis: Self.axis, labelWidth: { _ in 10 })
        let trunk = 200.0, lane = 30.0
        let y = trunk - lane
        func hit(_ x: Double, _ y: Double) -> WorkTimeline.Hit? {
            WorkTimeline.hit((x, y), lines: lines, releases: timeline.releases, axis: Self.axis, trunk: trunk, laneHeight: lane)
        }
        if case .dot(_, let dot) = hit(Self.axis.x(Self.h(-6)) + 3, y) { #expect(dot.number == "#80") } else { Issue.record("no dot") }
        if case .line(let line) = hit(Self.axis.x(Self.h(-4)), y + 5) { #expect(line.number == "#21") } else { Issue.record("no line") }
        if case .release(let r) = hit(Self.axis.x(Self.h(-12)), trunk) { #expect(r.tag == "v1.2.0") } else { Issue.record("no release") }
        #expect(hit(Self.axis.x(Self.h(-4)), y - 20) == nil)
    }

    @Test func theWordsSayAbout() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let backtest = DaemonAPI.WorkTimelineBacktest(error: 2.16, width: 1.3, cuts: 69, holds: 55, epics: 21, at: Self.now)
        let forecast = DaemonAPI.WorkTimelineForecast(low: Self.h(1), mid: Self.h(2), high: Self.h(4))
        let timeline = DaemonAPI.WorkTimeline(epics: [
            Self.epic(22, [Self.child(90, started: -3, closed: -1), Self.child(91, forecast: 2)], segments: [(-3, nil)],
                      forecast: forecast),
        ])
        let line = WorkTimeline.lines(timeline, now: Self.now)[0]
        let words = WorkTimeline.lineLine(line, now: Self.now, calendar: calendar)
        #expect(words.hasPrefix("#22 · 1 of 2 · closes about "))
        #expect(words.hasSuffix(", 8 in 10"))
        #expect(WorkTimeline.errorWords(backtest) == "Past forecasts were off by ×2.2")
        let spoken = WorkTimeline.spoken([line], now: Self.now, calendar: calendar)
        #expect(spoken.first?.words.hasPrefix("Issue 22, 1 of 2 done, closes about ") == true)
        #expect(WorkTimeline.waitWords(3) == "3 wait for you")
        #expect(WorkTimeline.waitWords(1) == "1 waits for you")
    }

    @Test func theHoverCardIsAMiniRow() throws {
        let timeline = DaemonAPI.WorkTimeline(epics: [
            Self.epic(30, [Self.child(31, started: -5, closed: -2), Self.child(32, started: -5, closed: -1, reason: "not_planned")],
                      segments: [(-5, -1)]),
            Self.epic(33, [Self.child(34, started: -3), Self.child(35, waits: true)], segments: [(-3, nil)]),
        ])
        let lines = WorkTimeline.lines(timeline, now: Self.now)
        let joined = try #require(lines.first { $0.number == "#30" })
        #expect(WorkTimeline.lineLine(joined, now: Self.now) == "#30 · 2 of 2 · closed 1 h ago")
        #expect(joined.dots.map { WorkTimeline.dotLine($0, now: Self.now) }
            == ["#31 · closed 2 h ago", "#32 · closed as not planned 1 h ago"])
        let waits = try #require(lines.first { $0.number == "#33" })
        #expect(WorkTimeline.lineLine(waits, now: Self.now) == "#33 · 0 of 2 · 1 waits for you")
        let release = DaemonAPI.WorkTimelineRelease(tag: "v1", at: Self.h(-3), repo: "alexec/Agents")
        #expect(WorkTimeline.releaseLine(release, now: Self.now) == "alexec/Agents · released 3 h ago")
        #expect(WorkTimeline.releaseLine(.init(tag: "v2", at: Self.now, repo: "a/b"), now: Self.now) == "a/b · released just now")
    }

    @Test func theTitleLineAndTheEmptyCardSayTheRange() {
        #expect(WorkTimeline.titleWords(project: "Agents", epics: 6, range: .twoDays) == "Agents · 6 epics in these 2 days")
        #expect(WorkTimeline.titleWords(project: "", epics: 1, range: .day) == "1 epic in these 24 hours")
        #expect(WorkTimeline.noEpicsWords(.week) == "No epic in these 7 days")
        let timeline = DaemonAPI.WorkTimeline(epics: [
            Self.epic(40, [Self.child(41, closed: -100)], segments: [(-120, -100)]),
            Self.epic(42, [Self.child(43, closed: -96)], segments: [(-110, -96)]),
            Self.epic(44, [Self.child(45, started: -2)], segments: [(-2, nil)]),
        ])
        let joined = WorkTimeline.lastJoined(timeline, before: Self.h(-24))
        #expect(joined == Self.h(-96))
        #expect(WorkTimeline.lastJoinedWords(Self.h(-96), now: Self.now) == "The last one joined 4 d ago.")
        #expect(WorkTimeline.lastJoined(timeline, before: Self.h(-200)) == nil)
        let lines = WorkTimeline.lines(timeline, now: Self.now)
        #expect(WorkTimeline.epicCount(lines, in: WorkTimeline.Range.twoDays.window(now: Self.now)) == 1)
    }

    @Test func machinesMergeEachEpicAndReleaseOnce() {
        let a = DaemonAPI.WorkTimeline(epics: [Self.epic(23, [Self.child(1, closed: -1)], segments: [(-2, -1)])],
                                       releases: [.init(tag: "v2", at: Self.h(-1), repo: "a/b")], errors: ["x"])
        let b = DaemonAPI.WorkTimeline(epics: [Self.epic(23, [Self.child(1, closed: -1)], segments: [(-2, -1)])],
                                       releases: [.init(tag: "v1", at: Self.h(-3), repo: "a/b"), .init(tag: "v2", at: Self.h(-1), repo: "a/b")],
                                       errors: ["x", "y"])
        let merged = WorkTimeline.merge([a, b])
        #expect(merged.epics.count == 1)
        #expect(merged.releases.map(\.tag) == ["v1", "v2"])
        #expect(merged.errors == ["x", "y"])
    }

    @Test func timelineIsAWorkListWithNoLineagePage() {
        #expect(WorkList.Kind.allCases.last == .timeline)
        #expect(WorkList.kind(of: Node(kind: "timeline", ref: "x")) == nil)
    }
}
