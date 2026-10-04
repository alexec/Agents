import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// What the workflow layer costs a Mac doing nothing, and one fire (#218): the numbers
/// in the commit. Timed, so off unless asked for.
@Suite("Workflow costs", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["AGENTS_BENCH"] == "1", "set AGENTS_BENCH=1 to time"))
struct WorkflowCostBenchmarks {
    private func temporary() throws -> (StoreLocations, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsWorkflowCost-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (StoreLocations(root: root), root.resolvingSymlinksInPath())
    }

    private func stamp(_ url: URL) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(inode)|\(modified)"
    }

    /// An idle root, no workflows, the real fifteen-second clock, for a minute.
    @Test func idleWritesPerMinute() async throws {
        let (locations, _) = try temporary()
        defer { try? FileManager.default.removeItem(at: locations.root) }
        let core = DaemonCore(store: try AgentStore(locations: locations), locations: locations,
                              discovery: .findsEverything, launcher: FakeLauncher())
        await core.loadFromDisk()
        await core.startWorkflows()
        var last = stamp(locations.workflows)
        var changes = 0
        let end = Date().addingTimeInterval(61)
        while Date() < end {
            try await Task.sleep(for: .milliseconds(200))
            let now = stamp(locations.workflows)
            if now != last { changes += 1; last = now }
        }
        print("#218 idle: workflows.json written \(changes) times in 61 s")
    }

    /// Fifty approved workflows in one project; one is off, and is fired by its schedule
    /// a hundred times: each fire is refused, and recorded.
    @Test func oneFire() async throws {
        let (locations, root) = try temporary()
        defer { try? FileManager.default.removeItem(at: locations.root) }
        let work = Project.standardize(root.appendingPathComponent("api", isDirectory: true))
        try FileManager.default.createDirectory(at: WorkflowFile.folder(in: work), withIntermediateDirectories: true)
        for index in 0..<50 {
            try Data("""
                ---
                on:
                  - schedule:
                      at: [":00"]
                agent: new\(index == 0 ? "\nenabled: false" : "")
                ---

                Workflow \(index): \(String(repeating: "Look at the tests. ", count: 40))
                """.utf8).write(to: WorkflowFile.url(for: String(format: "w%02d", index), in: work))
        }
        let core = DaemonCore(store: try AgentStore(locations: locations), locations: locations,
                              discovery: .findsEverything, launcher: FakeLauncher())
        await core.loadFromDisk()
        await core.rescanWorkflows(in: work)
        await core.startWorkflows()
        let workflow = try #require(await core.workflows[work]?["w00"])
        _ = await core.allWorkflows(in: work)
        let (reads, writes) = (await core.workflowDigestReads, await core.workflowStore.writes)
        let fires = 100
        let clock = ContinuousClock()
        let took = await clock.measure {
            for _ in 0..<fires { await core.fire(workflow, on: .schedule(WorkflowSchedule())) }
        }
        let each = took / fires
        print("#218 fire: \(each) each, over \(fires) refused fires with 50 workflows")
        let read = await core.workflowDigestReads - reads
        let written = await core.workflowStore.writes - writes
        print("#218 fire: \(Double(read) / Double(fires)) workflow files read and hashed, "
            + "\(Double(written) / Double(fires)) workflows.json writes, each")
    }
}
