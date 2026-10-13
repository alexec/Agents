import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// The measure P20261008-1 asked for: what polling writes to `mcp-events.json` with five
/// subscriptions to a stand-in server, each holding 2,000 seen ids, over 20 idle polls of
/// each, 30 s apart, and how long a cheap call to the core waits meanwhile.
/// Off unless `AGENTS_MEASURE_P20261008_1` is set; it prints, it does not judge.
@Suite("Measure MCP record writes (P20261008-1)",
       .enabled(if: ProcessInfo.processInfo.environment["AGENTS_MEASURE_P20261008_1"] != nil))
struct MCPRecordWritesMeasure {
    @Test func twentyIdlePollsOfFiveSubscriptions() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsMeasureMCP-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = Project.standardize(root.appendingPathComponent("work", isDirectory: true))
        try FileManager.default.createDirectory(at: project.appending(path: ".agents"), withIntermediateDirectories: true)
        let locations = StoreLocations(root: root.appendingPathComponent("root", isDirectory: true))
        try locations.createDirectories()
        let stand = EventsServerStandIn()
        try Data("{\"mcpServers\":{\"ci\":{\"type\":\"http\",\"url\":\"\(stand.url)\"}}}".utf8)
            .write(to: project.appending(path: ".agents/mcp.json"))
        let folder = WorkflowFile.folder(in: project)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let subscriptions = 5
        for n in 0..<subscriptions {
            try Data("---\non:\n  - checks.failed:\n      repo: r\(n)\nagent: new\n---\n\nFix it.\n".utf8)
                .write(to: WorkflowFile.url(for: "fix\(n)", in: project))
        }
        let now = MovableNow()

        func start(_ clock: PollClock) async throws -> DaemonCore {
            let core = DaemonCore(store: try AgentStore(locations: locations), locations: locations,
                                  discovery: .findsEverything, launcher: FakeLauncher(), now: now.now)
            await core.loadFromDisk()
            await core.rescanWorkflows(in: project)
            await core.startMCPEvents(http: EventsServerStandIn.route([stand]), sleep: clock.sleep)
            try await until { clock.sleeping == subscriptions }
            return core
        }
        func until(_ check: () async -> Bool) async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(30))
            while ContinuousClock.now < deadline {
                if await check() { return }
                try await Task.sleep(for: .milliseconds(2))
            }
            Issue.record("timed out")
            throw CancellationError()
        }

        // Subscribe, then seed each record with 2,000 seen ids, as a busy week leaves it.
        let first = try await start(PollClock())
        await first.stopMCPEvents()
        let store = MCPEventStore(root: locations.root)
        var records = store.load()
        #expect(records.subscriptions.count == subscriptions)
        for id in records.subscriptions.keys {
            records.subscriptions[id]?.see((0..<MCPSubscriptionRecord.seenLimit).map { "seeded-\(id.suffix(6))-\($0)" },
                                           at: now.now())
        }
        try store.save(records)

        let clock = PollClock()
        let core = try await start(clock)
        let writes = await core.mcpEvents.recordWrites
        let bytes = await core.mcpEvents.recordBytes

        // A cheap call to the core, again and again, while the polls run.
        let calling = Task {
            var waits: [Duration] = []
            while !Task.isCancelled {
                let at = ContinuousClock.now
                _ = await core.mcpRecords()
                waits.append(ContinuousClock.now - at)
                try? await Task.sleep(for: .microseconds(200))
            }
            return waits
        }
        let polls = 20
        let began = ContinuousClock.now
        for _ in 0..<polls {
            let before = stand.polls.count
            now.advance(30)
            clock.tick()
            try await until { stand.polls.count >= before + subscriptions && clock.sleeping == subscriptions }
        }
        let took = ContinuousClock.now - began
        calling.cancel()
        let waits = await calling.value.sorted()
        let wrote = await core.mcpEvents.recordWrites - writes
        let wroteBytes = await core.mcpEvents.recordBytes - bytes
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: store.url.path)[.size] as? Int) ?? 0
        await core.stopMCPEvents()

        func ms(_ d: Duration) -> String { String(format: "%.3f", Double(d.components.attoseconds) / 1e15 + Double(d.components.seconds) * 1000) }
        print("""
            MEASURE-P20261008-1 polls: \(polls) x \(subscriptions) subscriptions, file \(fileSize) bytes
            MEASURE-P20261008-1 writes: \(wrote) bytes: \(wroteBytes)
            MEASURE-P20261008-1 polls took ms: \(ms(took))
            MEASURE-P20261008-1 cheap call ms: n \(waits.count) p50 \(ms(waits[waits.count / 2])) \
            p99 \(ms(waits[waits.count * 99 / 100])) max \(ms(waits.last ?? .zero))
            """)
    }
}
