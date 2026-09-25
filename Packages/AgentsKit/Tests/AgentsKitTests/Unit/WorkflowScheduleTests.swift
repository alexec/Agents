import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// When a workflow that runs on a clock next runs.
///
/// Every case here is one the arithmetic would get wrong and the calendar gets right,
/// which is why `nextDue` walks rather than computes.
@Suite("The next time a schedule comes round")
struct WorkflowScheduleTests {
    /// A fixed calendar, so a test does not mean something different in another country.
    private func calendar(_ zone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }

    private func date(_ text: String, in zone: String = "Europe/London") -> Date {
        let formatter = DateFormatter()
        formatter.calendar = calendar(zone)
        formatter.timeZone = TimeZone(identifier: zone)!
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: text)!
    }

    @Test func theNextHalfHour() {
        let schedule = WorkflowSchedule(minutes: [0, 30])
        let next = schedule.nextDue(after: date("2026-09-19 09:05"), calendar: calendar("Europe/London"))
        #expect(next == date("2026-09-19 09:30"))
    }

    @Test func aScheduleDueExactlyNowGivesTheFollowingOne() {
        // Otherwise a tick that fires a workflow hands the same moment straight back
        // and it fires again on the next pass.
        let schedule = WorkflowSchedule(minutes: [0, 30])
        let next = schedule.nextDue(after: date("2026-09-19 09:30"), calendar: calendar("Europe/London"))
        #expect(next == date("2026-09-19 10:00"))
    }

    @Test func itCrossesADayBoundary() {
        let schedule = WorkflowSchedule(minutes: [0], hours: 9...9)
        let next = schedule.nextDue(after: date("2026-09-19 14:00"), calendar: calendar("Europe/London"))
        #expect(next == date("2026-09-20 09:00"))
    }

    @Test func itSkipsToTheNextAllowedDay() {
        // Friday afternoon, weekdays only, so the answer is Monday.
        let schedule = WorkflowSchedule(minutes: [0], hours: 9...9, days: Weekday.weekdays)
        let next = schedule.nextDue(after: date("2026-09-18 14:00"), calendar: calendar("Europe/London"))
        #expect(next == date("2026-09-21 09:00"))
    }

    @Test func aSpringForwardDoesNotLoseTheFire() {
        // On 29 March 2026 the London clocks go forward at 1am: 01:30 does not exist.
        // A workflow set for 01:30 must still come round, on the following day, rather
        // than returning nil or spinning.
        let schedule = WorkflowSchedule(minutes: [30], hours: 1...1)
        let next = schedule.nextDue(after: date("2026-03-28 12:00"), calendar: calendar("Europe/London"))
        #expect(next != nil)
        #expect(next! > date("2026-03-28 12:00"))
    }

    @Test func aFallBackDoesNotFireTwice() {
        // On 25 October 2026 the London clocks go back: 01:30 happens twice. Asking
        // again from the moment just returned must move forward, never stand still.
        let schedule = WorkflowSchedule(minutes: [30], hours: 1...1)
        let calendar = calendar("Europe/London")
        let first = schedule.nextDue(after: date("2026-10-24 12:00"), calendar: calendar)
        #expect(first != nil)
        let second = schedule.nextDue(after: first!, calendar: calendar)
        #expect(second != nil)
        #expect(second! > first!)
    }

    @Test func theAnswerFollowsTheTimeZone() {
        // The same schedule, asked in two places, is two different instants. This is
        // why nothing is precomputed.
        let schedule = WorkflowSchedule(minutes: [0], hours: 9...9)
        let from = date("2026-09-19 00:00", in: "UTC")
        let london = schedule.nextDue(after: from, calendar: calendar("Europe/London"))
        let newYork = schedule.nextDue(after: from, calendar: calendar("America/New_York"))
        #expect(london != newYork)
    }

    @Test func aScheduleThatNamesNoMinutesNeverFires() {
        #expect(WorkflowSchedule(minutes: []).nextDue(after: Date()) == nil)
    }

    @Test func aScheduleThatNamesNoDaysNeverFires() {
        #expect(WorkflowSchedule(minutes: [0], days: []).nextDue(after: Date()) == nil)
    }

    @Test func aWorkflowTakesTheSoonestOfItsSchedules() {
        let workflow = Workflow(
            workflowID: "two-clocks",
            folder: URL(filePath: "/tmp/p"),
            triggers: [.schedule(WorkflowSchedule(minutes: [0], hours: 17...17)),
                       .schedule(WorkflowSchedule(minutes: [0], hours: 9...9))],
            prompt: "go")
        let next = workflow.nextDue(after: date("2026-09-19 07:00"), calendar: calendar("Europe/London"))
        #expect(next == date("2026-09-19 09:00"))
    }

    // MARK: The minutes at either end of a range

    /// `between: 09:00-18:00` ends at six. Read as hours alone it ran until half past,
    /// while the page said "between 9am and 6pm".
    @Test func aRangeEndingOnTheHourDoesNotRunAtHalfPast() {
        let file = WorkflowFile.parse("""
            ---
            on:
              - schedule:
                  at: [":00", ":30"]
                  between: "09:00-18:00"
            ---
            Check.
            """, workflowID: "check", in: URL(filePath: "/tmp/p"))
        let schedule = try! #require(file.schedules.first)
        let london = calendar("Europe/London")
        #expect(schedule.matches(date("2026-09-19 18:00"), calendar: london))
        #expect(!schedule.matches(date("2026-09-19 18:30"), calendar: london))
        #expect(schedule.nextDue(after: date("2026-09-19 18:05"), calendar: london)
                == date("2026-09-20 09:00"))
        #expect(file.summary.contains("between 9am and 6pm"))
    }

    @Test func aRangeStartingOnTheHalfHourDoesNotRunBeforeIt() {
        let file = WorkflowFile.parse("""
            ---
            on:
              - schedule:
                  at: [":00", ":30"]
                  between: "09:30-17:30"
            ---
            Check.
            """, workflowID: "check", in: URL(filePath: "/tmp/p"))
        let schedule = try! #require(file.schedules.first)
        let london = calendar("Europe/London")
        #expect(!schedule.matches(date("2026-09-19 09:00"), calendar: london))
        #expect(schedule.matches(date("2026-09-19 09:30"), calendar: london))
        #expect(schedule.matches(date("2026-09-19 17:30"), calendar: london))
        #expect(file.summary.contains("between 9:30am and 5:30pm"))
    }

    /// A time nothing can fire at is refused rather than rounded one way or the other.
    @Test func aRangeAtAMinuteNothingRunsAtIsRefused() {
        for between in ["09:45-18:00", "09:00-17:15", "10:30-10:00"] {
            let file = WorkflowFile.parse("""
                ---
                on:
                  - schedule:
                      at: ":00"
                      between: "\(between)"
                ---
                Check.
                """, workflowID: "check", in: URL(filePath: "/tmp/p"))
            #expect(file.problem != nil, "\(between) should be refused")
        }
    }

    /// A schedule from an older daemon has neither minute, and means the whole of both
    /// hours by it.
    @Test func aScheduleWithoutRangeMinutesStillReads() throws {
        let old = #"{"minutes":[0,30],"hours":[9,18],"days":["mon"]}"#
        let schedule = try JSONDecoder().decode(WorkflowSchedule.self, from: Data(old.utf8))
        #expect(schedule.startMinute == 0)
        #expect(schedule.endMinute == 30)
    }
}
