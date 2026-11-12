import Foundation
import Testing
@testable import AgentsKitCore

/// Workflow hours (#4818): a schedule's `between:` past midnight reads and matches as the
/// daemon's does, and `hours:` has its Swift twin.
@Suite("Workflow hours")
struct WorkflowHoursTests {
    static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/London")!
        return c
    }()

    static func at(_ day: Int, _ hour: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour))! // the 13th is a Friday
    }

    @Test func aSchedulePastMidnightDecodesAndMatches() throws {
        let json = Data(#"{"minutes":[0],"hours":[22,2],"startMinute":0,"endMinute":0,"days":["fri"]}"#.utf8)
        let s = try JSONDecoder().decode(WorkflowSchedule.self, from: json)
        #expect(s.firstHour == 22 && s.lastHour == 2)
        for (date, want) in [(Self.at(13, 22), true), (Self.at(13, 23), true), (Self.at(14, 0), true), (Self.at(14, 2), true),
                             (Self.at(14, 3), false), (Self.at(13, 1), false), (Self.at(14, 22), false)] {
            #expect(s.matches(date, calendar: Self.calendar) == want, "\(date)")
        }
        #expect(s.nextDue(after: Self.at(13, 12), calendar: Self.calendar) == Self.at(13, 22))
        #expect(s.summary == "Fri on the hour between 10pm and 2am")
        // Written as it was read.
        let again = try JSONDecoder().decode(WorkflowSchedule.self, from: JSONEncoder().encode(s))
        #expect(again == s)
    }

    @Test func aScheduleInsideTheDayIsAsBefore() {
        let s = WorkflowSchedule(minutes: [0, 30], hours: 9...17, startMinute: 30, endMinute: 0, days: Weekday.weekdays)
        #expect(!s.matches(Self.at(13, 9), calendar: Self.calendar))
        #expect(s.matches(Self.at(13, 17), calendar: Self.calendar))
        #expect(!s.matches(Self.at(14, 12), calendar: Self.calendar))
    }

    @Test func betweenAsTheDaemonReadsIt() throws {
        let night = try WorkflowHours.parse(between: "18:00-09:00").get()
        #expect(night.from == 18 * 60 && night.to == 9 * 60)
        let day = try WorkflowHours.parse(between: "9-17:30").get()
        #expect(day.from == 9 * 60 && day.to == 17 * 60 + 30)
        #expect(throws: WorkflowHours.Failure(text: "9-25")) { try WorkflowHours.parse(between: "9-25").get() }
        #expect(throws: WorkflowHours.Failure(text: "09:15-10:00")) { try WorkflowHours.parse(between: "09:15-10:00").get() }
        #expect(throws: WorkflowHours.Failure(text: "09:00-09:00", isEmpty: true)) { try WorkflowHours.parse(between: "09:00-09:00").get() }
        #expect(WorkflowHours.Failure(text: "x").message == "\"x\" is not a range of times, like \"09:00-18:00\"")
    }

    @Test func hoursInWordsAndOnTheWire() throws {
        let h = WorkflowHours(between: "18:00-09:00", days: [.mon, .fri], timeZone: "Europe/London")
        #expect(h.words == "only 18:00-09:00 on Mon, Fri (Europe/London)")
        #expect(WorkflowHours(timeZone: "UTC").words == nil)
        let json = String(decoding: try JSONEncoder().encode(Workflow(workflowID: "x", folder: URL(filePath: "/p"), hours: h)), as: UTF8.self)
        #expect(json.contains(#""hours":{"#))
        let refusal = WorkflowRefusal.outsideHours(until: nil)
        #expect(refusal.isHeld && !refusal.needsAPerson && refusal.code == "outside_hours")
        #expect(WorkflowOutcome.refused(refusal, at: .now, repeats: 2).summary
            == "Waiting — 2 triggers held into one run, as it is outside its hours, and its hours name no day")
        #expect(WorkflowRefusal.codes.contains("outside_hours"))
    }

    /// The status card and the row (#4819): the window, and when a held trigger runs.
    @Test func theCardSaysTheWindowAndWhenItOpens() throws {
        let london = TimeZone(identifier: "Europe/London")!
        let ny = TimeZone(identifier: "America/New_York")!
        let work = WorkflowHours(between: "9-18", days: [.mon, .tue, .wed, .thu, .fri])
        #expect(work.sentence(viewer: london) == "Runs 09:00–18:00, Mon–Fri")
        let night = WorkflowHours(between: "18:00-09:30", days: [.sat, .sun, .mon, .wed], timeZone: "Europe/London")
        #expect(night.sentence(viewer: london) == "Runs 18:00–09:30, Mon, Wed, Sat, Sun")
        #expect(night.sentence(viewer: ny) == "Runs 18:00–09:30, Mon, Wed, Sat, Sun (Europe/London)")
        #expect(WorkflowHours(days: Array(Weekday.everyDay)).sentence(viewer: london) == nil)
        #expect(WorkflowHours(days: []).sentence(viewer: london) == "Never runs on its own: its hours name no day")

        // Monday 2026-11-16 09:00 in London is 04:00 in New York.
        let opens = try #require(Self.calendar.date(from: DateComponents(year: 2026, month: 11, day: 16, hour: 9)))
        var held = WorkflowSummary(workflow: Workflow(workflowID: "w", folder: URL(filePath: "/p"), hours: night),
                                   holdsAFire: true, hoursOpenAt: opens)
        #expect(held.waitsForItsHours)
        #expect(held.hoursOpenSentence(viewer: london) == "Waits for its hours: opens Mon 09:00")
        #expect(held.hoursOpenSentence(viewer: ny) == "Waits for its hours: opens Mon 09:00 (Europe/London)")
        #expect(held.hoursRowSentence(viewer: london) == "Waits for its hours: opens Mon 09:00")
        held.holdsAFire = false
        #expect(!held.waitsForItsHours)
        #expect(held.hoursOpenSentence(viewer: london) == "Outside its hours: opens Mon 09:00")
        held.hoursOpenAt = nil
        #expect(held.hoursRowSentence(viewer: london) == "Runs 18:00–09:30, Mon, Wed, Sat, Sun")
        held.isArchived = true
        #expect(held.hoursRowSentence(viewer: london) == nil)
        #expect(WorkflowRefusal.outsideHours(until: nil).isOutsideHours && !WorkflowRefusal.coolingDown(until: nil).isOutsideHours)
    }
}
