import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// Update now (#146): the Dashboard's button runs the project's workflow labelled
/// `dashboard` as Run now would, or starts a one-off agent when there is none; one at a
/// time, not again within five minutes, and never past the file's approval.
@Suite("Dashboard Update now", .timeLimit(.minutes(1)))
struct DashboardUpdateTests {
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var date = Date(timeIntervalSince1970: 1_800_000_000)
        var now: Date { lock.withLock { date } }
        func advance(minutes: Double) { lock.withLock { date = date.addingTimeInterval(minutes * 60) } }
    }

    private func temporary() throws -> (StoreLocations, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsDashboardUpdate-\(UUID().uuidString)", isDirectory: true)
        let work = root.appendingPathComponent("api", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        return (StoreLocations(root: root.appendingPathComponent("root", isDirectory: true)), Project.standardize(work))
    }

    /// The #138 workflow's shape: labelled `dashboard`, and off.
    private func writeWorkflow(_ id: String, labels: String = "[nightly, dashboard]", in project: URL) throws {
        try FileManager.default.createDirectory(at: WorkflowFile.folder(in: project), withIntermediateDirectories: true)
        try Data("""
            ---
            name: Update the dashboard
            on:
              - schedule:
                  at: [":00"]
            agent: new
            labels: \(labels)
            enabled: false
            ---

            Bring the tiles up to date.
            """.utf8).write(to: WorkflowFile.url(for: id, in: project))
    }

    private func core(_ locations: StoreLocations, clock: Clock) async throws -> DaemonCore {
        try locations.createDirectories()
        let core = DaemonCore(store: try AgentStore(locations: locations), locations: locations,
                              discovery: .findsEverything, launcher: FakeLauncher(), now: { clock.now })
        await core.loadFromDisk()
        return core
    }

    private func refusal(_ body: () async throws -> Void) async -> String? {
        do {
            try await body()
            return nil
        } catch let error as JSONRPCError {
            #expect(error.code == DaemonAPI.Failure.dashboardRefused, "\(error.message)")
            return error.message
        } catch {
            Issue.record("unexpected \(error)")
            return nil
        }
    }

    private func eventually(_ what: String, _ check: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: max(.seconds(20), Eventually.timeout))
        while ContinuousClock.now < deadline {
            if try await check() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("never happened: \(what)")
    }

    @Test func itRunsTheDashboardWorkflowEvenWhenItIsOff() async throws {
        let (locations, work) = try temporary()
        try writeWorkflow("update-dashboard", in: work)
        try writeWorkflow("other", labels: "[nightly]", in: work)
        let clock = Clock()
        let core = try await core(locations, clock: clock)
        await core.rescanWorkflows(in: work)
        await core.startWorkflows()

        let before = try #require(await core.dashboardSnapshot(work).update)
        #expect(before.workflowID == "update-dashboard")
        #expect(before.name == "Update the dashboard")
        #expect(before.lastStartedAt == nil)
        #expect(before.canPress(now: clock.now))

        let after = try await core.updateDashboard(.init(folder: work))
        #expect(after.lastStartedAt == clock.now)
        try await eventually("the workflow started one agent") { await core.allAgents().count == 1 }
        let agent = try #require(await core.allAgents().first)
        #expect(agent.startedByWorkflow == "update-dashboard")
        #expect(agent.labels.map(\.value).contains("dashboard"))
        let summary = try #require(await core.allWorkflows(in: work).first { $0.workflowID == "update-dashboard" })
        #expect(summary.isEnabled == false, "pressing it does not turn it on")
        guard case .byHand? = summary.lastFiredBy else {
            Issue.record("expected a run by hand, got \(String(describing: summary.lastFiredBy))"); return
        }
    }

    @Test func aSecondPressWithinFiveMinutesIsRefusedAndOneAfterRuns() async throws {
        let (locations, work) = try temporary()
        try writeWorkflow("update-dashboard", in: work)
        let clock = Clock()
        let core = try await core(locations, clock: clock)
        await core.rescanWorkflows(in: work)
        await core.startWorkflows()

        _ = try await core.updateDashboard(.init(folder: work))
        try await eventually("the run is over") {
            let running = await core.dashboardSnapshot(work).update?.isRunning
            let count = await core.allAgents().count
            return running == false && count == 1
        }
        clock.advance(minutes: 2)
        let state = try #require(await core.dashboardSnapshot(work).update)
        #expect(!state.canPress(now: clock.now))
        #expect(state.readyAt(now: clock.now) == Date(timeIntervalSince1970: 1_800_000_000 + 300))
        let message = await refusal { _ = try await core.updateDashboard(.init(folder: work)) }
        #expect(message?.contains("less than 5 minutes ago") == true)
        #expect(await core.allAgents().count == 1, "the refused press started nothing")

        clock.advance(minutes: 4)
        _ = try await core.updateDashboard(.init(folder: work))
        try await eventually("a second agent") { await core.allAgents().count == 2 }
    }

    @Test func aFileWaitingForApprovalIsSaidAndStartsNothing() async throws {
        let (locations, work) = try temporary()
        let clock = Clock()
        let core = try await core(locations, clock: clock)
        await core.rescanWorkflows(in: work)
        await core.startWorkflows()
        // Written after approval began, so it waits for the person.
        try writeWorkflow("update-dashboard", in: work)
        await core.rescanWorkflows(in: work)

        let state = try #require(await core.dashboardSnapshot(work).update)
        #expect(state.blocked == "Update the dashboard is waiting for approval")
        #expect(state.line(now: clock.now) == "Update now can't start: Update the dashboard is waiting for approval")
        let message = await refusal { _ = try await core.updateDashboard(.init(folder: work)) }
        #expect(message?.contains("waiting for approval") == true)
        #expect(await core.allAgents().isEmpty)
    }

    @Test func withNoWorkflowItStartsAOneOffAgent() async throws {
        let (locations, work) = try temporary()
        try writeWorkflow("nightly", labels: "[nightly]", in: work)
        let clock = Clock()
        let core = try await core(locations, clock: clock)
        await core.rescanWorkflows(in: work)
        await core.startWorkflows()

        let before = try #require(await core.dashboardSnapshot(work).update)
        #expect(before.workflowID == nil)
        #expect(before.name == DashboardUpdate.oneOffTitle)

        let after = try await core.updateDashboard(.init(folder: work))
        let agentID = try #require(after.agentID)
        #expect(after.lastStartedAt == clock.now)
        let agent = try #require(await core.agent(agentID))
        #expect(agent.title == DashboardUpdate.oneOffTitle)
        #expect(agent.startedByWorkflow == nil)
        #expect(agent.labels.map(\.value) == ["dashboard"])
        #expect(agent.projectFolder == work)

        let message = await refusal { _ = try await core.updateDashboard(.init(folder: work)) }
        #expect(message != nil, "running, or within five minutes: refused either way")
        #expect(await core.allAgents().count == 1)
    }

    @Test func anArchivedDashboardWorkflowIsPassedOverForTheOneOff() async throws {
        let (locations, work) = try temporary()
        try writeWorkflow("update-dashboard", in: work)
        let core = try await core(locations, clock: Clock())
        await core.rescanWorkflows(in: work)
        await core.startWorkflows()
        _ = try await core.archiveWorkflow(.init(folder: work, workflowID: "update-dashboard", archived: true))
        #expect(await core.dashboardSnapshot(work).update?.workflowID == nil)
    }

    @Test func aRowSummaryDoesNotReadTheWorkflows() async throws {
        let (locations, work) = try temporary()
        let core = try await core(locations, clock: Clock())
        #expect(await core.dashboardSnapshot(work, withUpdate: false).update == nil)
    }
}

/// What the page says about Update now, on every screen.
@Suite("Dashboard Update now words")
struct DashboardUpdateWordsTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    @Test func runningIsSaidFirst() {
        let state = DashboardUpdate(workflowID: "update-dashboard", isRunning: true, lastStartedAt: now, blocked: "x")
        #expect(state.line(now: now, calendar: calendar) == "Update the dashboard is running")
        #expect(!state.canPress(now: now))
    }

    @Test func neverRunSaysNothing() {
        let state = DashboardUpdate()
        #expect(state.line(now: now) == nil)
        #expect(state.canPress(now: now))
    }

    @Test func theCooldownEndsFiveMinutesAfterTheStart() {
        let state = DashboardUpdate(lastStartedAt: now)
        #expect(state.readyAt(now: now.addingTimeInterval(60)) == now.addingTimeInterval(300))
        #expect(state.readyAt(now: now.addingTimeInterval(300)) == nil)
        #expect(!state.canPress(now: now.addingTimeInterval(299)))
        #expect(state.canPress(now: now.addingTimeInterval(300)))
    }

    @Test func aFailedRunIsSaidOverTheCooldown() {
        let state = DashboardUpdate(lastStartedAt: now, lastFailed: true)
        #expect(state.line(now: now.addingTimeInterval(60), calendar: calendar)?.hasPrefix("The last update, ") == true)
        #expect(state.line(now: now.addingTimeInterval(60), calendar: calendar)?.hasSuffix("did not finish") == true)
    }

    @Test func timesAre24HourAndAnOldRunIsDated() {
        // 1_800_000_000 is 15 Jan 2027, 08:00 UTC.
        let state = DashboardUpdate(lastStartedAt: now)
        #expect(state.line(now: now.addingTimeInterval(60), calendar: calendar) == "Last update 08:00; again from 08:05")
        #expect(state.line(now: now.addingTimeInterval(3 * 86_400), calendar: calendar) == "Last update 15 Jan 08:00")
    }

    @Test func aSnapshotFromAnOlderHostDecodesWithNoButton() throws {
        let json = #"{"folder":"file:///tmp/p/","tiles":[],"now":0}"#
        let decoded = try JSONDecoder().decode(DashboardSnapshot.self, from: Data(json.utf8))
        #expect(decoded.update == nil)
    }
}
