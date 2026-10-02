import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// Turning a workflow off and on, apart from archiving it (#100).
///
/// Off keeps the workflow where it is: listed, holding its place under the ceiling,
/// runnable by hand. What it stops is every trigger, and each one it stops leaves a
/// `disabled` refusal, so a workflow off since Tuesday says so on its row.
@Suite("Turning a workflow off", .timeLimit(.minutes(1)))
struct WorkflowEnabledTests {
    private func temporary() throws -> (StoreLocations, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsWorkflowEnabled-\(UUID().uuidString)", isDirectory: true)
        let work = root.appendingPathComponent("api", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        return (StoreLocations(root: root), Project.standardize(work))
    }

    @discardableResult
    private func write(_ on: String, as workflowID: String, in project: URL) throws -> URL {
        let folder = WorkflowFile.folder(in: project)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = WorkflowFile.url(for: workflowID, in: project)
        try Data("---\non:\n\(on)\nagent: new\n---\n\nGo.\n".utf8).write(to: url)
        return url
    }

    private let halfHourly = "  - schedule:\n      at: [\":00\", \":30\"]"

    private func core(_ locations: StoreLocations, script: FakeACPAgent.Script = .init()) async throws -> DaemonCore {
        let core = DaemonCore(store: try AgentStore(locations: locations), locations: locations,
                              discovery: .findsEverything, launcher: FakeLauncher(script: script))
        await core.loadFromDisk()
        return core
    }

    private func turn(_ core: DaemonCore, _ folder: URL, _ id: String, on: Bool) async throws {
        _ = try await core.setWorkflowEnabled(
            DaemonAPI.WorkflowEnableRequest(folder: folder, workflowID: id, enabled: on))
    }

    private func summary(_ core: DaemonCore, _ folder: URL, _ id: String) async -> WorkflowSummary? {
        await core.allWorkflows(in: folder).first { $0.workflowID == id }
    }

    private func eventually(_ what: String, _ check: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: max(.seconds(20), Eventually.timeout))
        while ContinuousClock.now < deadline {
            if try await check() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("never happened: \(what)")
    }

    private var nineOClock: Date {
        var when = DateComponents()
        when.year = 2026; when.month = 9; when.day = 18; when.hour = 8; when.minute = 59
        return Calendar.current.date(from: when)!
    }

    @Test func anOffScheduleStaysListedWithNoNextTimeAndRefusesOnTheClock() async throws {
        let (locations, work) = try temporary()
        let url = try write(halfHourly, as: "nightly", in: work)
        let before = try Data(contentsOf: url)
        let core = try await core(locations)
        await core.rescanWorkflows(in: work)
        try await turn(core, work, "nightly", on: false)

        let off = try #require(await summary(core, work, "nightly"))
        #expect(off.isEnabled == false)
        #expect(off.isArchived == false)
        #expect(off.nextFireAt == nil)

        await core.tickWorkflows(now: nineOClock)
        await core.tickWorkflows(now: nineOClock.addingTimeInterval(60))
        await core.tickWorkflows(now: nineOClock.addingTimeInterval(31 * 60))

        guard case .refused(.disabled, _, let repeats) = await summary(core, work, "nightly")?.lastOutcome else {
            Issue.record("expected a disabled refusal"); return
        }
        #expect(repeats >= 1)
        #expect(await core.allAgents().isEmpty)
        #expect(try Data(contentsOf: url) == before, "turning off never touches the file")
        // Not news: the log is spared a refusal every half hour.
        #expect(!(await core.eventLog.events.contains { $0.name == "workflow.refused" }))
    }

    @Test func turningItBackOnBringsBackTheNextTimeAndTheFiring() async throws {
        let (locations, work) = try temporary()
        try write(halfHourly, as: "nightly", in: work)
        let core = try await core(locations)
        await core.rescanWorkflows(in: work)
        try await turn(core, work, "nightly", on: false)
        try await turn(core, work, "nightly", on: true)

        #expect(await summary(core, work, "nightly")?.isEnabled == true)
        #expect(await summary(core, work, "nightly")?.nextFireAt != nil)

        await core.tickWorkflows(now: nineOClock)
        await core.tickWorkflows(now: nineOClock.addingTimeInterval(60))
        try await eventually("the schedule started an agent") { await core.allAgents().count == 1 }
        let fired = await summary(core, work, "nightly")
        guard case .trigger(.schedule(let schedule)) = fired?.lastFiredBy else {
            Issue.record("expected the schedule as the cause, got \(String(describing: fired?.lastFiredBy))")
            return
        }
        #expect(schedule.minutes == [0, 30])
        #expect(fired?.lastFiredAt != nil)
    }

    @Test func anOffEventWorkflowIsRefusedOnTheEventAndStartsNothing() async throws {
        let (locations, work) = try temporary()
        try write("  - mac.wake", as: "catch-up", in: work)
        let core = try await core(locations)
        await core.rescanWorkflows(in: work)
        try await turn(core, work, "catch-up", on: false)

        let wake = await core.raise(EventDraft(name: "mac.wake", scope: .mac, sentence: "This Mac woke up."))
        try await eventually("refused on the event") {
            await core.eventLog.event(at: wake.position)?.consequences
                == [.refused(workflowID: "catch-up", folder: work, reason: .disabled)]
        }
        #expect(await core.allAgents().isEmpty)
        guard case .refused(.disabled, _, _) = await summary(core, work, "catch-up")?.lastOutcome else {
            Issue.record("expected a disabled refusal on the row"); return
        }
    }

    @Test func eachScheduleHasItsOwnNextTimeAndOffHasNone() async throws {
        let (locations, work) = try temporary()
        try write("  - agent-finished\n  - schedule:\n      at: [\":00\"]\n  - schedule:\n      at: [\":30\"]",
                  as: "two-clocks", in: work)
        let core = try await core(locations)
        await core.rescanWorkflows(in: work)
        let on = try #require(await summary(core, work, "two-clocks"))
        #expect(on.nextFireAtByTrigger.count == 3)
        #expect(on.nextFireAtByTrigger[0] == nil)
        let hour = try #require(on.nextFireAtByTrigger[1]), half = try #require(on.nextFireAtByTrigger[2])
        #expect(Calendar.current.component(.minute, from: hour) == 0)
        #expect(Calendar.current.component(.minute, from: half) == 30)
        #expect(on.nextFireAt == min(hour, half))

        try await turn(core, work, "two-clocks", on: false)
        #expect(await summary(core, work, "two-clocks")?.nextFireAtByTrigger.isEmpty == true)
    }

    @Test func runNowStillRunsAnOffWorkflowAndSaysItWasByHand() async throws {
        let (locations, work) = try temporary()
        try write(halfHourly, as: "nightly", in: work)
        let core = try await core(locations)
        await core.rescanWorkflows(in: work)
        try await turn(core, work, "nightly", on: false)

        try await core.runWorkflow(DaemonAPI.WorkflowRequest(folder: work, workflowID: "nightly"))

        #expect(await core.allAgents().count == 1)
        let ran = await summary(core, work, "nightly")
        #expect(ran?.lastFiredBy == .byHand)
        #expect(ran?.isEnabled == false, "running it by hand does not turn it on")
    }

    @Test func anOffWorkflowKeepsItsPlaceUnderTheCeiling() async throws {
        // Off for an afternoon must not let a fourth workflow in, which would then be
        // pushed back out when the first is turned on again.
        let (locations, work) = try temporary()
        for name in ["a-one", "b-two", "c-three", "d-four"] { try write(halfHourly, as: name, in: work) }
        let core = try await core(locations)
        await core.rescanWorkflows(in: work)
        try await turn(core, work, "a-one", on: false)

        #expect(await summary(core, work, "a-one")?.overLimit == nil)
        #expect(await summary(core, work, "d-four")?.overLimit == .project)
    }

    @Test func theStateSurvivesTheDaemonGoing() async throws {
        let (locations, work) = try temporary()
        try write(halfHourly, as: "nightly", in: work)
        do {
            let core = try await core(locations)
            await core.rescanWorkflows(in: work)
            try await turn(core, work, "nightly", on: false)
        }
        let again = try await core(locations)
        await again.rescanWorkflows(in: work)
        #expect(await summary(again, work, "nightly")?.isEnabled == false)
    }

    @Test func anOlderSummaryWithoutTheKeyReadsAsOn() throws {
        let summary = WorkflowSummary(workflow: Workflow(workflowID: "x", folder: URL(fileURLWithPath: "/tmp/x")))
        var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(summary)) as? [String: Any])
        object.removeValue(forKey: "isEnabled")
        object["lastOutcome"] = ["refused": ["_0": ["fromTheFuture": [:]], "at": 0, "repeats": 1]]
        let decoded = try JSONDecoder().decode(WorkflowSummary.self,
                                               from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.isEnabled)
        #expect(decoded.lastOutcome == nil, "an outcome this version does not know costs only the outcome")
    }
}
