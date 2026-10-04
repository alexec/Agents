import Foundation
import Synchronization
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// `mac.disk_low` and `mac.disk_ok` from the daemon (#195), with a reading a test sets
/// rather than a disk it fills.
@Suite("Disk space events", .timeLimit(.minutes(1)))
struct DiskEventTests {
    /// One volume whose free space the test says.
    final class FakeVolume: Sendable {
        let free = Mutex<Int64>(400 * DiskSpace.gigabyte)
        func set(_ gb: Double) { free.withLock { $0 = Int64(gb * Double(DiskSpace.gigabyte)) } }
        var reader: @Sendable (URL) -> DiskReading? {
            { [self] _ in
                DiskReading(volume: "Work", mount: "/Volumes/Work", freeBytes: free.withLock { $0 },
                            totalBytes: 1000 * DiskSpace.gigabyte)
            }
        }
    }

    private func temporary() throws -> (StoreLocations, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsDisk-\(UUID().uuidString)", isDirectory: true)
        let work = root.appendingPathComponent("api", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        return (StoreLocations(root: root.appendingPathComponent("store")), Project.standardize(work))
    }

    private func core(_ locations: StoreLocations, volume: FakeVolume, adding work: URL? = nil) async throws -> DaemonCore {
        let core = DaemonCore(store: try AgentStore(locations: locations), locations: locations,
                              discovery: .findsEverything, launcher: FakeLauncher())
        await core.loadFromDisk()
        await core.useForEvents(holdLimit: .milliseconds(100))
        await core.useDiskReader(volume.reader)
        if let work { _ = try await core.addProject(work) }
        return core
    }

    private func diskEvents(_ core: DaemonCore) async -> [Event] {
        await core.eventLog.events.filter { $0.name.hasPrefix("mac.disk_") }
    }

    @Test func aDropIsRaisedOnceWithItsDetailsAndTheClimbBackOnce() async throws {
        let (locations, work) = try temporary()
        let volume = FakeVolume()
        let core = try await core(locations, volume: volume, adding: work)

        await core.checkDiskSpace()
        #expect(await diskEvents(core).isEmpty, "plenty free says nothing")
        #expect(await core.diskState().alarms.isEmpty)

        volume.set(30)
        await core.checkDiskSpace()
        await core.checkDiskSpace()
        var events = await diskEvents(core)
        #expect(events.map(\.name) == ["mac.disk_low"], "one crossing, one event")
        let low = try #require(events.first)
        #expect(low.scope == .mac)
        #expect(low.details["volume"] == "Work")
        #expect(low.details["free_bytes"] == String(30 * DiskSpace.gigabyte))
        #expect(low.details["free_percent"] == "3")
        #expect(low.details["level"] == "low")
        #expect(low.details["threshold"] == String(50 * DiskSpace.gigabyte))
        #expect(low.sentence == "Work is running low: 30.0 GB free.")
        #expect(await core.diskState().alarms.map(\.level) == [.low])

        volume.set(1)
        await core.checkDiskSpace()
        events = await diskEvents(core)
        #expect(events.last?.details["level"] == "critical")

        volume.set(52)
        await core.checkDiskSpace()
        #expect(await diskEvents(core).count == 2, "inside the margin is still low")
        volume.set(60)
        await core.checkDiskSpace()
        events = await diskEvents(core)
        #expect(events.map(\.name) == ["mac.disk_low", "mac.disk_low", "mac.disk_ok"])
        #expect(events.last?.details["threshold"] == String(50 * DiskSpace.gigabyte))
        #expect(await core.diskState().alarms.isEmpty)
    }

    @Test func aWorkflowCanTriggerOnItAndNarrowByLevel() {
        func parse(_ on: String) -> Workflow {
            WorkflowFile.parse("---\non:\n\(on)\n---\n\nClean up.\n", workflowID: "w",
                               in: URL(fileURLWithPath: "/tmp/project"))
        }
        let both = parse("  - mac.disk_low:\n      level: critical\n  - mac.disk_ok")
        #expect(both.problem == nil)
        #expect(both.triggers == [.event(EventPattern("mac.disk_low", filters: ["level": "critical"])),
                                  .event(EventPattern("mac.disk_ok"))])
        guard case .unreadable(let detail)? = parse("  - mac.disk_low:\n      level: full").problem else {
            Issue.record("a level it cannot have was taken")
            return
        }
        #expect(detail.contains("low"), "\(detail)")
        #expect(EventCatalogue.describe().contains("- mac.disk_low [volume, free_bytes, free_percent, "
                                                   + "level=low|critical, threshold, worktrees]"))
    }

    @Test func theProjectsFileMovesTheLine() async throws {
        let (locations, work) = try temporary()
        let volume = FakeVolume()
        let core = try await core(locations, volume: volume, adding: work)
        _ = try await core.setDiskSpace(.init(folder: work, diskSpace: DiskThresholds(lowGB: 100)))
        let text = try String(contentsOf: ProjectConfig.url(in: work), encoding: .utf8)
        #expect(text.contains("\"lowGB\" : 100"))
        #expect(await core.projectSummary(for: work)?.project.diskSpace == DiskThresholds(lowGB: 100))

        volume.set(80)
        await core.checkDiskSpace()
        #expect(await diskEvents(core).first?.details["threshold"] == String(100 * DiskSpace.gigabyte))

        await #expect(throws: (any Error).self) {
            _ = try await core.setDiskSpace(.init(folder: work, diskSpace: DiskThresholds(lowGB: 5, criticalGB: 10)))
        }
    }

    @Test func theLargestWorktreesAreNamedBiggestFirst() async throws {
        let (locations, work) = try temporary()
        let volume = FakeVolume()
        let core = try await core(locations, volume: volume, adding: work)
        let worktrees = work.appending(path: WorktreeName.folder, directoryHint: .isDirectory)
        for (name, size) in [("small", 10_000), ("big", 400_000)] {
            let folder = worktrees.appending(path: name, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(count: size).write(to: folder.appending(path: "blob"))
        }
        volume.set(10)
        await core.checkDiskSpace()
        let low = try #require(await diskEvents(core).first)
        let named = try #require(low.details["worktrees"])
        #expect(named.hasPrefix("big "), "\(named)")
        #expect(named.contains("small "))
        #expect(await core.diskState().alarms.first?.worktrees.map(\.name) == ["big", "small"])
    }

    @Test func aRestartWhileLowDoesNotSayItAgainButStillShowsTheStrip() async throws {
        let (locations, work) = try temporary()
        let volume = FakeVolume()
        volume.set(30)
        let first = try await core(locations, volume: volume, adding: work)
        await first.checkDiskSpace()
        #expect(await diskEvents(first).count == 1)
        await first.shutDown()

        let again = try await core(locations, volume: volume)
        await again.checkDiskSpace()
        #expect(await diskEvents(again).count == 1, "the same crossing, already said")
        #expect(await again.diskState().alarms.map(\.level) == [.low])
    }
}
