import AgentsKit
import AgentsKitCore
@testable import ControlPlaneKit
import Foundation
import Testing

// Wake-up calls (#1004): a stopped workspace is started a little before its host's next
// scheduled workflow, once for each due time, and not with its switch off; the idle stop
// leaves up a host whose workflow is due soon. The clock is passed in, so nothing waits for it.

extension ProviderHarness {
    /// Linked, its workspace stopped, and its host having said its next workflow is at `at`.
    func stoppedWithSchedule(at: Date, workflow: String = "Nightly review") async throws {
        try await link(try await add())
        await providers.heard(devbox, status: DaemonAPI.HostStatus(
            idle: true, schedule: DaemonAPI.HostSchedule(at: at, workflow: workflow)))
    }
}

@Suite("Wake-up calls (#1004)")
struct WakeUpCallsTests {
    /// A whole second, as a host's due times are whole minutes: dates go through JSON.
    static var inAnHour: Date { Date(timeIntervalSinceReferenceDate: Date().timeIntervalSinceReferenceDate.rounded() + 3600) }

    @Test func aStoppedWorkspaceStartsFiveMinutesBeforeItsWorkflowOnce() async throws {
        let h = try await ProviderHarness()
        let at = WakeUpCallsTests.inAnHour
        try await h.stoppedWithSchedule(at: at)
        let row = try await h.row()
        #expect(row.state == "stopped")
        #expect(row.workspace?.nextWorkflow == "Nightly review")
        #expect(row.workspace?.wakeAt == at.addingTimeInterval(-300))
        #expect(row.workspace?.tellsSchedule == true)

        await h.providers.wakeUps(now: at.addingTimeInterval(-301))
        #expect(await h.provider.starts == 0)
        await h.providers.wakeUps(now: at.addingTimeInterval(-299))
        _ = try await h.waitFor("starting") { $0.workspace?.phase == "connecting" }
        #expect(await h.provider.starts == 1)
        // Kept on the link, so a restart doesn't start it again for the same time (FR-006).
        #expect(await h.records.host(h.devbox)?.workspace?.wokeFor == at)

        await h.router.setState(.online, of: h.devbox)
        _ = try await h.waitFor("online") { $0.workspace?.phase == nil }
        await h.provider.set("agents-devbox", state: "stopped")
        await h.router.setState(.offline(since: Date()), of: h.devbox)
        await h.providers.refresh(nil)
        _ = try await h.waitFor("stopped")
        await h.providers.wakeUps(now: at.addingTimeInterval(-200))
        #expect(await h.provider.starts == 1)
        #expect(try await h.row().workspace?.wakeAt == nil)
    }

    @Test func theSwitchOffMakesNoWakeUpCall() async throws {
        let h = try await ProviderHarness()
        let at = WakeUpCallsTests.inAnHour
        try await h.stoppedWithSchedule(at: at)
        _ = try await h.call(DaemonAPI.Method.hostsSetWorkspaceOptions, try JSONValue.encoding(
            DaemonAPI.HostWorkspaceOptions(host: h.devbox, startForSchedules: false)))
        let row = try await h.row()
        #expect(row.workspace?.startForSchedules == false)
        #expect(row.workspace?.wakeAt == nil)
        await h.providers.wakeUps(now: at.addingTimeInterval(-60))
        #expect(await h.provider.starts == 0)
    }

    @Test func aHostFromBeforeSaysNoScheduleAndGetsNoCall() async throws {
        let h = try await ProviderHarness()
        try await h.link(try await h.add())
        await h.providers.heard(h.devbox, status: DaemonAPI.HostStatus(idle: true))
        let row = try await h.row()
        #expect(row.workspace?.tellsSchedule == false)
        #expect(row.workspace?.wakeAt == nil)
        await h.providers.wakeUps(now: Date())
        #expect(await h.provider.starts == 0)
    }

    @Test func aPastDueTimeStartsNothing() async throws {
        let h = try await ProviderHarness()
        let at = WakeUpCallsTests.inAnHour
        try await h.stoppedWithSchedule(at: at)
        await h.providers.wakeUps(now: at.addingTimeInterval(1))
        #expect(await h.provider.starts == 0)
    }

    @Test func aMeasuredStartMovesTheCallEarlier() {
        var link = WorkspaceLink(provider: ProviderID(rawValue: "p"), workspace: "w")
        #expect(WorkspaceProviders.lead(link) == 300)
        link.measuredStartSeconds = 400
        #expect(WorkspaceProviders.lead(link) == 520)
        let at = WakeUpCallsTests.inAnHour
        link.schedule = DaemonAPI.HostSchedule(at: at, workflow: "Nightly review")
        #expect(WorkspaceProviders.wakeAt(link, now: Date()) == at.addingTimeInterval(-520))
    }

    @Test func aWorkflowDueWithinTheIdleTimeKeepsItUp() {
        let now = Date()
        var link = WorkspaceLink(provider: ProviderID(rawValue: "p"), workspace: "w")
        #expect(!WorkspaceProviders.keptUp(link, idleFor: 1800, now: now))
        link.schedule = DaemonAPI.HostSchedule(at: now.addingTimeInterval(1200), workflow: "Nightly review")
        #expect(WorkspaceProviders.keptUp(link, idleFor: 1800, now: now))
        #expect(!WorkspaceProviders.keptUp(link, idleFor: 600, now: now))
        // Started for it: up until it runs, however short the idle time.
        link.wokeFor = link.schedule?.at
        #expect(WorkspaceProviders.keptUp(link, idleFor: 60, now: now))
    }

    @Test func anIdleHostStartedForItsWorkflowIsNotStopped() async throws {
        let h = try await ProviderHarness(timing: ProviderHarness.quick)
        try await h.onlineAndLinked(stopAfter: 2)
        let at = WakeUpCallsTests.inAnHour
        var record = try #require(await h.records.host(h.devbox))
        record.workspace?.wokeFor = at
        try await h.records.save(record)
        await h.providers.heard(h.devbox, status: DaemonAPI.HostStatus(
            idle: true, schedule: DaemonAPI.HostSchedule(at: at, workflow: "Nightly review")))
        try await Task.sleep(for: .milliseconds(200))
        #expect(await h.provider.stops == 0)
    }
}
