import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// The measure #216 asked for: what a wake costs on a project the size of a busy one —
/// 10 pins, 30 folders at the top — while an agent edits in the main checkout.
/// Off unless `AGENTS_MEASURE_216` is set; it prints, it does not judge. It touches only
/// what main had before #216, so the same file measures both.
@Suite("Measure a wake (#216)", .enabled(if: ProcessInfo.processInfo.environment["AGENTS_MEASURE_216"] != nil))
struct WakeCostMeasure {
    @Test func aWakeWhileAnAgentEdits() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsMeasure216-\(UUID().uuidString)", isDirectory: true)
        let work = Project.standardize(root.appendingPathComponent("work", isDirectory: true).resolvingSymlinksInPath())
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = FileManager.default
        for index in 0..<30 { try manager.createDirectory(at: work.appending(path: "Dir\(index)"), withIntermediateDirectories: true) }
        let locations = StoreLocations(root: root.appending(path: "store"))
        let core = DaemonCore(store: try AgentStore(locations: locations), locations: locations,
                              discovery: .findsEverything, launcher: FakeLauncher(script: FakeACPAgent.Script()))
        try await core.writePins(PinsFile(pins: (0..<10).map {
            PinEntry(path: "Dir\($0)/pin.md", pinnedBy: Pinner(person: true))
        }), in: work)

        // 1. The batch alone: an edit in a source folder, as the watch hands it over.
        let source = work.appending(path: "Dir20")
        await core.projectFilesChanged([source], in: work)
        var clock = ContinuousClock.now
        for _ in 0..<500 { await core.projectFilesChanged([source], in: work) }
        let batch = (ContinuousClock.now - clock) / 500
        // And one naming `.agents`, as a workflow or pin edit does.
        let agents = work.appending(path: ".agents/workflows")
        clock = ContinuousClock.now
        for _ in 0..<200 { await core.projectFilesChanged([agents, work.appending(path: ".agents")], in: work) }
        let agentsBatch = (ContinuousClock.now - clock) / 200

        // 2. The real watch, an agent writing 400 files over about four seconds.
        await core.watchProject(work)
        try await Task.sleep(for: .milliseconds(500))
        let wakes = await core.projectWatchWakes
        clock = ContinuousClock.now
        for round in 0..<40 {
            for file in 0..<10 {
                try Data("\(round)".utf8).write(to: work.appending(path: "Dir\(file + 10)/f\(file).swift"), options: .atomic)
            }
            // and git, as a lane's commit does
            try manager.createDirectory(at: work.appending(path: ".git/logs/refs/heads"), withIntermediateDirectories: true)
            try Data("\(round)".utf8).write(to: work.appending(path: ".git/logs/refs/heads/main"))
            try await Task.sleep(for: .milliseconds(100))
        }
        try await Task.sleep(for: .milliseconds(800))
        let watched = await core.projectWatchWakes - wakes
        await core.stopWatchingAllWorkflows()

        print("""
            MEASURE-216 batch(edit in a source folder): \(batch)
            MEASURE-216 batch(naming .agents): \(agentsBatch)
            MEASURE-216 wakes for 40 rounds of edits + git writes: \(watched)
            """)
    }
}
