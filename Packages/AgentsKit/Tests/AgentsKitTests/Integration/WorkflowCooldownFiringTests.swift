import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// A cooldown in a running daemon, on a clock the test moves (#103).
///
/// A trigger inside the cooldown is held, recorded on its event and on the row, and the
/// latest one held runs once when the clock passes the end. Run now is not held.
@Suite("Firing a workflow with a cooldown", .timeLimit(.minutes(1)))
struct WorkflowCooldownFiringTests {
    /// A clock the test moves, which the daemon reads as its own `now`.
    private final class ManualClock: @unchecked Sendable {
        private let lock = NSLock()
        private var date = Date(timeIntervalSinceReferenceDate: 812_000_000)
        func now() -> Date { lock.lock(); defer { lock.unlock() }; return date }
        func advance(minutes: Double) {
            lock.lock(); defer { lock.unlock() }
            date.addTimeInterval(minutes * 60)
        }
    }

    private func temporary() throws -> (StoreLocations, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsWorkflowCooldown-\(UUID().uuidString)", isDirectory: true)
        let work = root.appendingPathComponent("api", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        return (StoreLocations(root: root), Project.standardize(work))
    }

    private func write(cooldown: String, in project: URL) throws {
        let folder = WorkflowFile.folder(in: project)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("---\non:\n  - mac.wake\nagent: new\ncooldown: \(cooldown)\n---\n\nGo.\n".utf8)
            .write(to: WorkflowFile.url(for: "catch-up", in: project))
    }

    private func core(_ locations: StoreLocations, _ clock: ManualClock) async throws -> DaemonCore {
        let core = DaemonCore(store: try AgentStore(locations: locations), locations: locations,
                              discovery: .findsEverything, launcher: FakeLauncher(script: .init()),
                              now: { clock.now() })
        await core.loadFromDisk()
        return core
    }

    private func summary(_ core: DaemonCore, _ folder: URL) async -> WorkflowSummary? {
        await core.allWorkflows(in: folder).first { $0.workflowID == "catch-up" }
    }

    private func wake(_ core: DaemonCore, _ clock: ManualClock) async -> Event {
        await core.raise(EventDraft(name: "mac.wake", at: clock.now(), scope: .mac, sentence: "This Mac woke up."))
    }

    private func eventually(_ what: String, _ check: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: max(.seconds(20), Eventually.timeout))
        while ContinuousClock.now < deadline {
            if try await check() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("never happened: \(what)")
    }

    /// The first run, started and finished, so what follows is the cooldown and not the run.
    private func firstRun(_ core: DaemonCore, _ clock: ManualClock, _ work: URL) async throws {
        _ = await wake(core, clock)
        try await eventually("the first wake started an agent") { await core.allAgents().count == 1 }
        try await eventually("the first run finished") { await summary(core, work)?.isRunning == false }
    }

    @Test func triggersInsideAreHeldIntoOneRunWithTheLatestWhenItEnds() async throws {
        let clock = ManualClock()
        let (locations, work) = try temporary()
        try write(cooldown: "15m", in: work)
        let core = try await core(locations, clock)
        await core.rescanWorkflows(in: work)
        let started = clock.now()
        try await firstRun(core, clock, work)
        let end = started.addingTimeInterval(15 * 60)
        #expect(await summary(core, work)?.cooldownEndsAt == end)

        clock.advance(minutes: 5)
        let early = await wake(core, clock)
        try await eventually("the early wake was held on its event") {
            await core.eventLog.event(at: early.position)?.consequences
                == [.refused(workflowID: "catch-up", folder: work, reason: .coolingDown(until: end))]
        }
        clock.advance(minutes: 1)
        let latest = await wake(core, clock)
        try await eventually("the latest wake was held too") {
            await core.eventLog.event(at: latest.position)?.consequences.isEmpty == false
        }
        #expect(await core.allAgents().count == 1, "nothing ran inside the cooldown")
        let waiting = try #require(await summary(core, work))
        #expect(waiting.holdsAFire)
        guard case .refused(.coolingDown(until: end), _, 2) = waiting.lastOutcome else {
            Issue.record("expected two triggers held, got \(String(describing: waiting.lastOutcome))"); return
        }
        // Held is not news on the log; it is on the row and on each event.
        #expect(!(await core.eventLog.events.contains { $0.name == "workflow.refused" }))

        clock.advance(minutes: 3)
        await core.tickWorkflows(now: clock.now())
        #expect(await core.allAgents().count == 1, "still inside the cooldown at 9 minutes")

        clock.advance(minutes: 6)
        await core.tickWorkflows(now: clock.now())
        try await eventually("the held trigger ran once the cooldown ended") { await core.allAgents().count == 2 }
        // The latest of the burst is the one that ran, and only once.
        try await eventually("the run is on the latest wake") {
            await core.eventLog.event(at: latest.position)?.consequences.contains {
                if case .fired(workflowID: "catch-up", _, _) = $0 { return true }
                return false
            } == true
        }
        let ran = try #require(await summary(core, work))
        #expect(ran.holdsAFire == false)
        #expect(ran.lastFiredAt == clock.now())
        try await eventually("its run finished") { await summary(core, work)?.isRunning == false }
        await core.tickWorkflows(now: clock.now().addingTimeInterval(60))
        #expect(await core.allAgents().count == 2, "a held trigger runs once")
    }

    @Test func aTriggerOutsideRunsAtOnce() async throws {
        let clock = ManualClock()
        let (locations, work) = try temporary()
        try write(cooldown: "15m", in: work)
        let core = try await core(locations, clock)
        await core.rescanWorkflows(in: work)
        try await firstRun(core, clock, work)

        clock.advance(minutes: 15)
        _ = await wake(core, clock)
        try await eventually("a wake after the cooldown ran") { await core.allAgents().count == 2 }
        #expect(await summary(core, work)?.holdsAFire == false)
    }

    @Test func runNowIsNotHeldAndStartsTheCooldownAgain() async throws {
        let clock = ManualClock()
        let (locations, work) = try temporary()
        try write(cooldown: "15m", in: work)
        let core = try await core(locations, clock)
        await core.rescanWorkflows(in: work)
        try await firstRun(core, clock, work)

        clock.advance(minutes: 2)
        let byHand = try await core.runWorkflow(DaemonAPI.WorkflowRequest(folder: work, workflowID: "catch-up"))
        #expect(await core.allAgents().count == 2, "Run now inside the cooldown runs")
        #expect(byHand.lastFiredBy == .byHand)
        #expect(byHand.cooldownEndsAt == clock.now().addingTimeInterval(15 * 60))
    }

    @Test func aHeldTriggerSurvivesTheDaemonGoing() async throws {
        let clock = ManualClock()
        let (locations, work) = try temporary()
        try write(cooldown: "15m", in: work)
        do {
            let core = try await core(locations, clock)
            await core.rescanWorkflows(in: work)
            try await firstRun(core, clock, work)
            clock.advance(minutes: 5)
            _ = await wake(core, clock)
            try await eventually("held") { await summary(core, work)?.holdsAFire == true }
        }
        let again = try await core(locations, clock)
        await again.rescanWorkflows(in: work)
        #expect(await summary(again, work)?.holdsAFire == true)
        clock.advance(minutes: 10)
        await again.tickWorkflows(now: clock.now())
        try await eventually("the held trigger ran after the restart") {
            await again.allAgents().filter { $0.startedByWorkflow == "catch-up" }.count == 2
        }
    }

    @Test func turningItOffLetsTheHeldTriggerGo() async throws {
        let clock = ManualClock()
        let (locations, work) = try temporary()
        try write(cooldown: "15m", in: work)
        let core = try await core(locations, clock)
        await core.rescanWorkflows(in: work)
        try await firstRun(core, clock, work)
        clock.advance(minutes: 5)
        _ = await wake(core, clock)
        try await eventually("held") { await summary(core, work)?.holdsAFire == true }

        _ = try await core.setWorkflowEnabled(
            DaemonAPI.WorkflowEnableRequest(folder: work, workflowID: "catch-up", enabled: false))
        #expect(await summary(core, work)?.holdsAFire == false)
        clock.advance(minutes: 15)
        await core.tickWorkflows(now: clock.now())
        #expect(await core.allAgents().count == 1)
    }

    // MARK: Changed from the page

    @Test func thePageWritesItIntoTheFileAndLeavesItAloneWhenNotSent() async throws {
        let clock = ManualClock()
        let (locations, work) = try temporary()
        try write(cooldown: "15m", in: work)
        let core = try await core(locations, clock)
        await core.rescanWorkflows(in: work)
        let url = WorkflowFile.url(for: "catch-up", in: work)
        func request(_ cooldown: String?) -> DaemonAPI.WorkflowSettingsRequest {
            DaemonAPI.WorkflowSettingsRequest(folder: work, workflowID: "catch-up",
                                              settings: WorkflowSettings(), cooldown: cooldown)
        }

        let longer = try await core.setWorkflowSettings(request("1h30m"))
        #expect(longer.workflow.cooldown == TimeInterval(90 * 60))
        #expect(try String(contentsOf: url, encoding: .utf8).contains("cooldown: 1h30m\n"))

        // A phone from before #103 sends no cooldown, and must not remove it.
        let untouched = try await core.setWorkflowSettings(request(nil))
        #expect(untouched.workflow.cooldown == TimeInterval(90 * 60))

        await #expect(throws: JSONRPCError.self) { try await core.setWorkflowSettings(request("soon")) }
        #expect(try String(contentsOf: url, encoding: .utf8).contains("cooldown: 1h30m\n"), "a refusal writes nothing")

        let none = try await core.setWorkflowSettings(request(""))
        #expect(none.workflow.cooldown == nil)
        #expect(!(try String(contentsOf: url, encoding: .utf8).contains("cooldown")))
    }
}
