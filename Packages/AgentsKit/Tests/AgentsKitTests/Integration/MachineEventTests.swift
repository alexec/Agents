import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// The Mac and the person as events, and the other sources that are not agents,
/// workflows or pull requests (042 US5, R10–R11).
@Suite("Mac, person, cost and lease events", .timeLimit(.minutes(1)))
struct MachineEventTests {
    /// A Mac that sleeps when a test says so.
    final class FakeMachineWatch: MachineWatch, @unchecked Sendable {
        private let lock = NSLock()
        private var report: (@Sendable (MachineChange) -> Void)?
        func start(_ report: @escaping @Sendable (MachineChange) -> Void) { lock.withLock { self.report = report } }
        func stop() { lock.withLock { report = nil } }
        func send(_ change: MachineChange) { lock.withLock { report }?(change) }
    }

    private func temporary() throws -> (StoreLocations, URL, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsMachine-\(UUID().uuidString)", isDirectory: true)
        let p = root.appendingPathComponent("p", isDirectory: true)
        let q = root.appendingPathComponent("q", isDirectory: true)
        for folder in [p, q] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        return (StoreLocations(root: root.appendingPathComponent("store")), Project.standardize(p), Project.standardize(q))
    }

    private func core(_ locations: StoreLocations,
                      script: FakeACPAgent.Script = .init()) async throws -> DaemonCore {
        let core = DaemonCore(store: try AgentStore(locations: locations), locations: locations,
                              discovery: .findsEverything, launcher: FakeLauncher(script: script))
        await core.loadFromDisk()
        await core.useForEvents(holdLimit: .milliseconds(100))
        return core
    }

    private func eventually(_ what: String, _ check: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while ContinuousClock.now < deadline {
            if try await check() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("never happened: \(what)")
    }

    private func names(_ core: DaemonCore) async -> [String] { await core.eventLog.events.map(\.name) }

    @Test func sleepThenWakeAreBothRecordedInOrderOnTheMac() async throws {
        let (locations, _, _) = try temporary()
        let core = try await core(locations)
        let watch = FakeMachineWatch()
        await core.startWatchingMachine(watch)
        watch.send(.sleep)
        watch.send(.wake)
        try await eventually("both") { await names(core).filter { $0.hasPrefix("mac.") }.count == 2 }
        #expect(await names(core).filter { $0.hasPrefix("mac.") } == ["mac.sleep", "mac.wake"])
        #expect(await core.eventLog.events.allSatisfy { $0.scope == .mac })
    }

    @Test func aWaitInOneProjectAndAWorkflowInAnotherBothHearTheWake() async throws {
        let (locations, p, q) = try temporary()
        let folder = WorkflowFile.folder(in: q)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("---\non:\n  - mac.wake\nagent: new\n---\n\nCatch up.\n".utf8).write(to: WorkflowFile.url(for: "catch-up", in: q))
        let core = try await core(locations)
        await core.rescanWorkflows(in: q)
        let waiter = try await core.start(DaemonAPI.StartRequest(runtimeID: "claude", cwd: p, prompt: "Wait"))
        await core.bindAppToken("t", to: waiter)
        _ = try await core.waitForEvent(.init(token: "t", events: ["mac.wake"]))
        let watch = FakeMachineWatch()
        await core.startWatchingMachine(watch)
        watch.send(.wake)
        try await eventually("the workflow in q fired") {
            await core.allAgents().contains { $0.startedByWorkflow == "catch-up" }
        }
        try await eventually("the waiter in p woke") {
            await core.eventLog.events.first { $0.name == "mac.wake" }?.consequences
                .contains(.woke(agentID: waiter, title: "Wait")) == true
        }
    }

    @Test func lockingAndUnlockingAreAwayAndBack() async throws {
        let (locations, _, _) = try temporary()
        let core = try await core(locations)
        let watch = FakeMachineWatch()
        await core.startWatchingMachine(watch)
        watch.send(.away(why: "locked"))
        watch.send(.back(why: "locked"))
        try await eventually("both") { await names(core).filter { $0.hasPrefix("person.") }.count == 2 }
        let events = await core.eventLog.events.filter { $0.name.hasPrefix("person.") }
        #expect(events.map(\.name) == ["person.away", "person.back"])
        #expect(events.allSatisfy { $0.details["why"] == "locked" })
        #expect(events.first?.sentence == "You locked the screen.")
    }

    @Test func aCostLimitIsSaidOnceADay() async throws {
        let (locations, _, _) = try temporary()
        let core = try await core(locations)
        await core.raiseCostLimit("day", agent: nil)
        await core.raiseCostLimit("day", agent: nil)
        #expect(await names(core).filter { $0 == "cost.limit_reached" }.count == 1)
        #expect(await core.eventLog.events.last?.scope == .mac)
    }

    @Test func leasesGivenAndGivenBackAreOnTheMacsLog() async throws {
        let (locations, p, _) = try temporary()
        // Its turn held open: a turn that ends lets its token go, and the holder has two
        // calls to make with it.
        let core = try await core(locations, script: .init(gate: TurnGate()))
        await core.useForLeases(catalog: FixedCatalog([.screen]))
        let holder = try await core.start(DaemonAPI.StartRequest(runtimeID: "claude", cwd: p, prompt: "Hold"))
        await core.bindAppToken("h", to: holder)
        _ = try await core.lease(.init(token: "h", name: "screen"))
        _ = try await core.releaseLease(.init(token: "h", name: "screen"))
        let leases = await core.eventLog.events.filter { $0.name.hasPrefix("lease.") }
        #expect(leases.map(\.name) == ["lease.granted", "lease.released"])
        #expect(leases.last?.details["how"] == "released")
    }
}
