import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// The project index is made once and kept (#204): every project's folder and its name
/// among the others, let go only when a folder gains or loses its last agent, a record or
/// a tombstone. These check it against the long way round, `rebuiltProjects`, after every
/// one of many random changes, and that a project-wide call grows with the projects
/// rather than with their square.
@Suite("Project index", .timeLimit(.minutes(3)))
struct ProjectIndexTests {
    /// The same changes every run, so a failure can be run again.
    private struct Dice: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    private func temporary() throws -> (StoreLocations, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsIndexTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (StoreLocations(root: root.appendingPathComponent("root", isDirectory: true)),
                root.resolvingSymlinksInPath())
    }

    private func folder(_ root: URL, _ path: String) throws -> URL {
        let url = root.appendingPathComponent(path, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return Project.standardize(url)
    }

    private func core(_ locations: StoreLocations) async throws -> DaemonCore {
        try locations.createDirectories()
        let core = DaemonCore(store: try AgentStore(locations: locations), locations: locations,
                              discovery: .findsEverything, launcher: FakeLauncher(script: FakeACPAgent.Script()))
        await core.loadFromDisk()
        return core
    }

    private static let base = Date(timeIntervalSince1970: 1_790_000_000)

    private func agent(in folder: URL, _ n: Int) -> Agent {
        var agent = Agent(runtimeID: "claude", cwd: folder, title: "agent \(n)", state: .finished,
                          createdAt: Self.base.addingTimeInterval(Double(n)),
                          lastActivityAt: Self.base.addingTimeInterval(Double(n * 7 % 1_000)))
        agent.costToDate["USD"] = Decimal(n % 13) / 100
        return agent
    }

    private func byFolder(_ summaries: [DaemonAPI.ProjectSummary]) -> [URL: DaemonAPI.ProjectSummary] {
        Dictionary(summaries.map { ($0.folder, $0) }, uniquingKeysWith: { first, _ in first })
    }

    @Test func theIndexMatchesTheFullCountThroughAddRemoveRenameAndRetire() async throws {
        let (locations, root) = try temporary()
        // Two folders called api, so a third arriving renames the others.
        var folders = [try folder(root, "a/api"), try folder(root, "b/api"), try folder(root, "web"),
                       try folder(root, "docs")]
        let spare = [try folder(root, "c/api"), try folder(root, "d/docs"), try folder(root, "tools")]
        let core = try await core(locations)
        var dice = Dice(state: 204)
        var ids: [UUID] = []
        var n = 0
        for step in 0..<400 {
            let roll = Int.random(in: 0..<12, using: &dice)
            switch roll {
            case 0...2:
                // Add: an agent in a folder, perhaps one no project had.
                n += 1
                let agent = agent(in: folders.randomElement(using: &dice)!, n)
                ids.append(agent.id)
                await core.changed(agent)
            case 3 where !ids.isEmpty:
                // Rename: an agent moves to another folder, which may be new and named
                // like another, so every name of that kind moves.
                if !spare.isEmpty, Bool.random(using: &dice), let new = spare.randomElement(using: &dice),
                   !folders.contains(new) {
                    folders.append(new)
                }
                let id = ids.randomElement(using: &dice)!
                if var moved = await core.agent(id) {
                    moved.cwd = folders.randomElement(using: &dice)!
                    await core.changed(moved)
                }
            case 4 where !ids.isEmpty:
                // Remove: gone without a tombstone.
                let id = ids.remove(at: Int.random(in: 0..<ids.count, using: &dice))
                await core.forgetForTest(id)
            case 5 where !ids.isEmpty:
                // Tombstone: archived, then retired, as the cap retires one.
                let id = ids.remove(at: Int.random(in: 0..<ids.count, using: &dice))
                if var archived = await core.agent(id) {
                    archived.state = .archived
                    archived.archivedAt = Self.base
                    archived.archivedReason = .byUser
                    await core.changed(archived)
                    try await core.retire(id, because: .cap)
                }
            case 6:
                // A record: a folder added before anything ran in it.
                _ = try await core.addProject(spare.randomElement(using: &dice)!)
            case 7:
                // A record changed: put away and brought back.
                let folder = folders.randomElement(using: &dice)!
                if (try? await core.archiveProject(folder)) != nil, Bool.random(using: &dice) {
                    _ = try await core.unarchiveProject(folder)
                }
            default:
                if let id = ids.randomElement(using: &dice), var touched = await core.agent(id) {
                    touched.lastActivityAt = Self.base.addingTimeInterval(Double(Int.random(in: 0..<2_000, using: &dice)))
                    await core.changed(touched)
                }
            }
            let kept = byFolder(await core.allProjects())
            let rebuilt = byFolder(await core.rebuiltProjects())
            #expect(kept == rebuilt, "step \(step)")
            if kept != rebuilt { break }
            for folder in rebuilt.keys {
                #expect(await core.isProject(folder), "step \(step)")
            }
        }
        #expect(await core.retired.count > 0, "the walk retired something")
        await core.stopWatchingAllWorkflows()
    }

    @Test func aTombstoneTableKeepsEachProjectsNumbers() {
        let a = URL(filePath: "/tmp/index-a/"), b = URL(filePath: "/tmp/index-b/")
        func tombstone(_ folder: URL, _ cents: Int, created: Double, active: Double) -> Tombstone {
            var agent = Agent(runtimeID: "claude", cwd: folder, title: "gone", state: .archived,
                              createdAt: Self.base.addingTimeInterval(created),
                              lastActivityAt: Self.base.addingTimeInterval(active))
            agent.costToDate["USD"] = Decimal(cents) / 100
            agent.archivedAt = Self.base
            return Tombstone(from: agent, retiredAt: Self.base, because: .cap)
        }
        var table = TombstoneTable()
        let first = tombstone(a, 10, created: 5, active: 50)
        let second = tombstone(a, 20, created: 1, active: 90)
        table[first.id] = first
        let version = table.foldersVersion
        table[second.id] = second
        #expect(table.foldersVersion == version, "a second tombstone in a folder moves no folder")
        #expect(table.tallies[Project.standardize(a)] == TombstoneTally(
            count: 2, costToDate: ["USD": 0.3], oldestCreated: Self.base.addingTimeInterval(1),
            newestActivity: Self.base.addingTimeInterval(90)))

        // Taken away: the oldest and newest are found again from what is left.
        table[second.id] = nil
        #expect(table.tallies[Project.standardize(a)] == TombstoneTally(
            count: 1, costToDate: ["USD": 0.1], oldestCreated: Self.base.addingTimeInterval(5),
            newestActivity: Self.base.addingTimeInterval(50)))

        // Moved to another folder: the first has none left, the other has it.
        var moved = first
        moved.project = b
        table[first.id] = moved
        #expect(table.tallies[Project.standardize(a)] == nil)
        #expect(table.tallies[Project.standardize(b)]?.count == 1)
        #expect(table.foldersVersion > version)
        #expect(table.count == 1)
    }

    /// Projects with `perProject` agents each, every one in its own folder.
    private func seeded(_ projects: Int, perProject: Int = 2) async throws -> DaemonCore {
        let (locations, root) = try temporary()
        let core = try await core(locations)
        for p in 0..<projects {
            let folder = try folder(root, "p\(p)")
            for a in 0..<perProject { await core.changed(agent(in: folder, p * perProject + a)) }
        }
        return core
    }

    @Test func projectWideCallsReadTheIndexRatherThanMakeIt() async throws {
        let core = try await seeded(500)
        _ = await core.allProjects()
        let made = await core.projectIndexBuilds
        // Every project-wide call, and each project's own summary: none makes it again.
        #expect(await core.allProjects(includeArchived: false).count == 500)
        _ = await core.catchUp(DaemonAPI.CatchUpRequest())
        _ = await core.pinsList()
        _ = await core.dashboardSummaries()
        for project in await core.allProjects() {
            #expect(await core.projectSummary(for: project.folder) != nil)
            #expect(await core.isProject(project.folder))
        }
        #expect(await core.projectIndexBuilds == made)
        // A change that moves no folder leaves it as it was.
        if let some = await core.allAgents().first {
            var touched = some
            touched.lastActivityAt = Self.base.addingTimeInterval(9_999)
            await core.changed(touched)
        }
        _ = await core.allProjects()
        #expect(await core.projectIndexBuilds == made)
    }

    @Test func projectsListGrowsWithTheProjectsNotTheirSquare() async throws {
        func took(_ core: DaemonCore) async -> Double {
            let start = ContinuousClock.now
            _ = await core.allProjects()
            let took = (ContinuousClock.now - start).components
            return Double(took.seconds) + Double(took.attoseconds) / 1e18
        }
        let small = try await seeded(50)
        let large = try await seeded(500)
        // In turns, and the quickest of each, so a busy machine slows both alike.
        var at50 = Double.infinity, at500 = Double.infinity
        for _ in 0..<15 {
            at50 = min(at50, await took(small))
            at500 = min(at500, await took(large))
        }
        // Ten times the projects: about ten times the time when each costs the same, and a
        // hundred when each costs as much as all of them, as it did (#204).
        #expect(at500 < at50 * 30, "50 projects \(at50 * 1000) ms, 500 projects \(at500 * 1000) ms")
    }
}
