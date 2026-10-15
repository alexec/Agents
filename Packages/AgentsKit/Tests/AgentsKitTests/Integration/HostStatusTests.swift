import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// What a host tells its control plane about whether it is idle (#691 US4, FR-030), for its
/// workspace's stop when idle: a real agent through a real `DaemonCore`, said only on a change.
@Suite("A host says whether it is idle (#691)", .timeLimit(.minutes(1)))
struct HostStatusTests {
    final class Said: @unchecked Sendable {
        private let lock = NSLock()
        private var said: [DaemonAPI.HostStatus] = []
        func add(_ value: JSONValue) {
            guard let status = try? value.decode(DaemonAPI.HostStatus.self) else { return }
            lock.withLock { said.append(status) }
        }
        var all: [DaemonAPI.HostStatus] { lock.withLock { said } }
    }

    @Test func aTurnMakesItBusyAndItsEndIdleAgain() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsHostStatus-\(UUID().uuidString)", isDirectory: true)
        let work = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let locations = StoreLocations(root: root)
        var script = FakeACPAgent.Script()
        script.turnDelay = .milliseconds(600)
        let core = DaemonCore(store: try AgentStore(locations: locations), locations: locations,
                              discovery: .findsEverything, launcher: FakeLauncher(script: script))
        let said = Said()
        await core.deliverStatus { said.add($0) }
        #expect(said.all == [DaemonAPI.HostStatus(idle: true, schedule: .init())])

        let id = try await core.start(.init(runtimeID: "copilot", cwd: work, prompt: "do a thing"))
        await eventually("it is working") { await core.agent(id)?.state == .running }
        await core.reviseHostStatus()
        #expect(said.all.last?.idle == false)
        #expect(said.all.last?.running.count == 1)

        // Nothing moved: nothing said.
        let before = said.all.count
        await core.reviseHostStatus()
        #expect(said.all.count == before)

        await eventually("the turn ended") { await core.agent(id)?.state == .finished }
        await core.reviseHostStatus()
        #expect(said.all.last == DaemonAPI.HostStatus(idle: true, schedule: .init()))
    }

    /// Its next scheduled workflow, for the control plane's wake-up call (#1004 FR-002): the
    /// soonest that could fire here; one turned off or archived isn't counted.
    @Test func itSaysItsNextScheduledWorkflow() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsHostSchedule-\(UUID().uuidString)", isDirectory: true)
        let work = Project.standardize(root.appendingPathComponent("api", isDirectory: true))
        let folder = WorkflowFile.folder(in: work)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        func write(_ id: String, _ front: String) throws {
            try Data("---\n\(front)\nagent: new\n---\n\nGo.\n".utf8).write(to: WorkflowFile.url(for: id, in: work))
        }
        try write("nightly", "name: Nightly review\non:\n  - schedule:\n      at: [\":00\"]\n      between: \"03:00-03:00\"")
        try write("often", "name: Often\non:\n  - schedule:\n      at: [\":00\", \":30\"]\nenabled: false")
        try write("byhand", "name: By hand")
        let locations = StoreLocations(root: root)
        let core = DaemonCore(store: try AgentStore(locations: locations), locations: locations,
                              discovery: .findsEverything, launcher: FakeLauncher())
        await core.loadFromDisk()
        await core.rescanWorkflows(in: work)

        var when = DateComponents()
        when.year = 2026; when.month = 10; when.day = 14; when.hour = 23; when.minute = 40
        let night = Calendar.current.date(from: when)!
        let next = await core.nextScheduled(after: night)
        #expect(next.workflow == "Nightly review")
        when.day = 15; when.hour = 3; when.minute = 0
        #expect(next.at == Calendar.current.date(from: when))
    }
}
