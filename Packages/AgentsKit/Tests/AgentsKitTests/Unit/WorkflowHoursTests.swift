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
}

/// The Hours setting (#4820): what each control writes, as the web page's twin does.
@Suite("Workflow hours setting")
struct WorkflowHoursSettingTests {
    @Test func eachControlWritesAWholeHours() {
        let any = WorkflowHours()
        #expect(!any.limits)
        #expect(WorkflowHours.sentence(nil) == "Any time: a trigger starts it at any hour.")
        let working = WorkflowHours.working
        #expect(WorkflowHours.sentence(working)
                == "Starts only 09:00-17:00 on Mon, Tue, Wed, Thu, Fri. A trigger outside them waits, and starts it once they open.")
        #expect(working.window?.from == 540 && working.window?.to == 1020)
        // From keeps To; onto To, or from All day, eight hours.
        #expect(working.starting(at: 18 * 60).between == "18:00-17:00")
        #expect(working.starting(at: 17 * 60).between == "17:00-01:00")
        #expect(working.starting(at: nil).between == nil)
        #expect(any.starting(at: 22 * 60 + 30).between == "22:30-06:30")
        #expect(working.ending(at: 9 * 60 + 30)?.between == "09:00-09:30")
        #expect(working.ending(at: 9 * 60) == nil)
        #expect(any.ending(at: 60) == nil)
        // Days: every day is no days:, and the last one stays.
        #expect(working.toggling(.sat)?.days == [.mon, .tue, .wed, .thu, .fri, .sat])
        #expect(working.toggling(.sat)?.toggling(.sun)?.days == nil)
        #expect(WorkflowHours(days: [.mon]).toggling(.mon) == nil)
        #expect(any.toggling(.sun)?.days == [.mon, .tue, .wed, .thu, .fri, .sat])
        #expect(any.admits(.sun) && !working.admits(.sun))
        #expect(working.inZone("Europe/London").timeZone == "Europe/London")
        #expect(WorkflowHours.zones(with: "Mars/Up").contains("Mars/Up"))
        #expect(WorkflowHours.halfHours.count == 48)
        #expect(WorkflowHours.halfHours.map(WorkflowHours.clockText).last == "23:30")
    }
}
