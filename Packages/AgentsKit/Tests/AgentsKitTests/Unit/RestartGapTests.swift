import Foundation
import Testing
@testable import AgentsKitCore

/// How long the daemon was down, and the words a waiting agent is told (#1219).
@Suite("Restart gap")
struct RestartGapTests {
    let at = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func theReasonComesFromWhatTheLastDaemonLeft() {
        #expect(RestartGap(at: at, alive: nil).reason == .firstStart)
        #expect(RestartGap(at: at, alive: nil).downFor == nil)
        #expect(RestartGap(at: at, alive: nil).downForWords == "unknown")
        let crashed = RestartGap(at: at, alive: DaemonAlive(lastAlive: at.addingTimeInterval(-90)))
        #expect(crashed.reason == .crashed)
        #expect(crashed.downFor == 90)
        let stopped = RestartGap(at: at, alive: DaemonAlive(lastAlive: at.addingTimeInterval(-10),
                                                            stoppedAt: at.addingTimeInterval(-7_500)))
        #expect(stopped.reason == .stopped)
        #expect(stopped.downForWords == "2 h 5 min")
        #expect(stopped.details["down_for"] == "7500")
        #expect(stopped.details["reason"] == "stopped")
    }

    @Test func aClockSetBackIsNoGap() {
        #expect(RestartGap(at: at, alive: DaemonAlive(lastAlive: at.addingTimeInterval(60))).downFor == 0)
    }

    @Test func theWordsForTheLength() {
        func words(_ seconds: TimeInterval) -> String {
            RestartGap(at: at, reason: .crashed, downSince: at.addingTimeInterval(-seconds)).downForWords
        }
        #expect(words(40) == "40 s")
        #expect(words(180) == "3 min")
        #expect(words(3_600) == "1 h")
        #expect(words(3 * 86_400) == "3 days")
    }

    @Test func whatReplaysAndWhatDoesNot() {
        for name in ["pr.merged", "checks.*", "branch.moved", "system.restarted", "machine.disk_low", "person.back"] {
            #expect(EventWords.caughtUpAfterRestart(name), "\(name)")
        }
        for name in ["agent.finished", "agent.*", "lease.released", "mac.wake", "workflow.completed"] {
            #expect(!EventWords.caughtUpAfterRestart(name), "\(name)")
        }
    }

    @Test func aWaitIsToldOnlyWhatItMayHaveMissed() {
        let gap = RestartGap(at: at, reason: .crashed, downSince: at.addingTimeInterval(-180))
        let wait = EventWait(patterns: [EventPattern("agent.finished"), EventPattern("pr.merged")], from: 0, since: at)
        let notice = EventWords.restartNotice([gap], wait: wait)
        #expect(notice.contains("Events in that time may be missing: agent.finished. "))
        #expect(!notice.contains("missing: agent.finished, pr.merged"))
        #expect(EventWords.restartNotice([], wait: wait).isEmpty)
    }

    @Test func noServerMayRaiseASystemEvent() {
        #expect(EventCatalogue.reservedNouns.contains("system"))
        #expect(!EventCatalogue.isServerEventName("system.restarted"))
        #expect(EventCatalogue.kind(named: "system.restarted")?.isMacOnly == false)
    }
}
