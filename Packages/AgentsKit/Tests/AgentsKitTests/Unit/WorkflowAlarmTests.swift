import Foundation
import Testing
@testable import AgentsKitCore

/// A one-time alarm (#4966): read back by its name, said as the daemon says it, and how
/// late its run fired.
@Suite("A one-time alarm")
struct WorkflowAlarmTests {
    private func decode(_ json: String) throws -> WorkflowTrigger {
        try JSONDecoder().decode(WorkflowTrigger.self, from: Data(json.utf8))
    }

    @Test func itIsReadBackByItsNameAndWrittenAsItCame() throws {
        let json = #"{"unrecognised":{"name":"once","keys":{"at":"2026-11-13T09:15","time-zone":"UTC","grace":"30m"}}}"#
        let trigger = try decode(json)
        let alarm = try #require(trigger.alarm)
        #expect(trigger.isSupported)
        #expect(trigger.name == "once")
        #expect(alarm.graceSeconds == 1800)
        #expect(trigger.summary == "Once, at 2026-11-13 09:15 (UTC), or up to 30 minutes late")
        #expect(try decode(String(decoding: JSONEncoder().encode(trigger), as: UTF8.self)) == trigger)
    }

    @Test func itSaysHowLateItsRunFired() throws {
        let trigger = try decode(#"{"unrecognised":{"name":"once","keys":{"at":"2026-11-13T09:15","due":"2026-11-13T09:15:00Z"}}}"#)
        let alarm = try #require(trigger.alarm)
        #expect(trigger.summary == "Once, at 2026-11-13 09:15 in your time zone, or up to 1 hour late")
        let due = try #require(alarm.due)
        #expect(alarm.lateness(firedAt: due.addingTimeInterval(20)) == "on time")
        #expect(alarm.lateness(firedAt: due.addingTimeInterval(12 * 60)) == "12 minutes late")
        #expect(WorkflowCause.trigger(trigger).phrase == "by its one-time alarm")
        #expect(WorkflowAlarm.lengthWords(125 * 60) == "2 hours 5 minutes")
    }

    @Test func oneWithNoTimeIsNotAnAlarm() throws {
        let trigger = try decode(#"{"unrecognised":{"name":"once","keys":{}}}"#)
        #expect(trigger.alarm == nil)
        #expect(!trigger.isSupported)
    }
}
