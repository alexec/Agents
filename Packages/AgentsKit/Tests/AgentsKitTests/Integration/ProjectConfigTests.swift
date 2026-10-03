import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// A project's helper limits live in its own `.agents/project.json` (#126), so they
/// travel with it to every clone and host.
@Suite("Project settings in the project", .timeLimit(.minutes(1)))
struct ProjectConfigTests {
    private func temporary() throws -> (StoreLocations, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsProjectConfig-\(UUID().uuidString)", isDirectory: true)
        let work = root.appendingPathComponent("api", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        return (StoreLocations(root: root), Project.standardize(work))
    }

    private func core(_ locations: StoreLocations, adding work: URL? = nil) async throws -> DaemonCore {
        let core = DaemonCore(store: try AgentStore(locations: locations), locations: locations,
                              discovery: .findsEverything, launcher: FakeLauncher())
        await core.loadFromDisk()
        if let work { _ = try await core.addProject(work) }
        return core
    }

    private func file(_ work: URL) -> URL { ProjectConfig.url(in: work) }
    private func read(_ work: URL) throws -> String { try String(contentsOf: file(work), encoding: .utf8) }

    @Test func settingWritesTheFileAndTheDefaultsTakeItAway() async throws {
        let (locations, work) = try temporary()
        let core = try await core(locations, adding: work)

        let set = try await core.setHelperLimits(.init(folder: work, limits: HelperLimits(running: 4, notArchived: 8)))
        #expect(set.helperLimits == (4, 8))
        #expect(try read(work) == """
            {
              "helperLimits" : {
                "notArchived" : 8,
                "running" : 4
              }
            }

            """)
        let kept = ProjectStore(locations: locations).load().first { $0.folder == work }
        #expect(kept?.helperLimits == nil, "nothing about the limits is in projects.json")

        _ = try await core.setHelperLimits(.init(folder: work, limits: HelperLimits()))
        #expect(!FileManager.default.fileExists(atPath: file(work).path), "no file for a project with nothing to say")
    }

    @Test func otherKeysAreKeptAndTheSameSettingWritesNothing() async throws {
        let (locations, work) = try temporary()
        try FileManager.default.createDirectory(at: file(work).deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"later": {"thing": true}}"#.utf8).write(to: file(work))
        let core = try await core(locations, adding: work)

        _ = try await core.setHelperLimits(.init(folder: work, limits: HelperLimits(agentsMayArchive: false)))
        let first = try read(work)
        #expect(first.contains(#""later""#) && first.contains(#""agentsMayArchive" : false"#))
        let stamp = try FileManager.default.attributesOfItem(atPath: file(work).path)[.modificationDate] as? Date

        try await Task.sleep(for: .milliseconds(20))
        _ = try await core.setHelperLimits(.init(folder: work, limits: HelperLimits(agentsMayArchive: false)))
        let again = try FileManager.default.attributesOfItem(atPath: file(work).path)[.modificationDate] as? Date
        #expect(stamp == again, "the same setting again is not a write")

        _ = try await core.setHelperLimits(.init(folder: work, limits: HelperLimits()))
        #expect(try read(work).contains(#""later""#), "the file stays for the key it still holds")
        #expect(!(try read(work)).contains("helperLimits"))
    }

    @Test func anotherCloneReadsTheSameLimitsAndAHandEditPastTheMaximumIsHeldToIt() async throws {
        let (locations, work) = try temporary()
        let core = try await core(locations, adding: work)
        _ = try await core.setHelperLimits(.init(folder: work, limits: HelperLimits(running: 2, notArchived: 9)))

        let (elsewhere, clone) = try temporary()
        try FileManager.default.createDirectory(at: file(clone).deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: file(work), to: file(clone))
        let there = try await self.core(elsewhere, adding: clone)
        let limits = try #require(await there.projectSummary(for: clone)?.helperLimits)
        #expect(limits == (2, 9))

        try Data(#"{"helperLimits": {"running": 50, "notArchived": 99}}"#.utf8).write(to: file(clone))
        await there.projectConfigFilesChanged([file(clone)], in: clone)
        #expect(await there.helperLimits(in: clone) == (HelperLimit.maximumRunning, HelperLimit.maximumNotArchived))
    }

    @Test func aFileThatIsNotAnObjectIsLeftAloneAndSaidSo() async throws {
        let (locations, work) = try temporary()
        try FileManager.default.createDirectory(at: file(work).deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: file(work))
        let core = try await core(locations, adding: work)
        await #expect(throws: JSONRPCError.self) {
            _ = try await core.setHelperLimits(.init(folder: work, limits: HelperLimits(running: 2)))
        }
        #expect(try read(work) == "not json")
        #expect(await core.helperLimits(in: work) == (3, 5), "an unreadable file is the defaults")
    }

    @Test func limitsKeptInProjectsJsonAreMovedIntoTheFileOnce() async throws {
        let (locations, work) = try temporary()
        let away = Project.standardize(work.deletingLastPathComponent().appendingPathComponent("away", isDirectory: true))
        try ProjectStore(locations: locations).save([
            Project(folder: work, helperLimits: HelperLimits(running: 2, notArchived: 4)),
            Project(folder: away, helperLimits: HelperLimits(running: 1)),
        ])
        let core = try await core(locations)
        await core.startWorkflows()

        #expect(ProjectConfig.helperLimits(in: work) == HelperLimits(running: 2, notArchived: 4))
        #expect(await core.helperLimits(in: work) == (2, 4))
        let kept = ProjectStore(locations: locations).load()
        #expect(kept.first { $0.folder == work }?.helperLimits == nil)
        #expect(kept.first { $0.folder == away }?.helperLimits == HelperLimits(running: 1),
                "a folder that is away keeps its record for later")
        #expect(await core.helperLimits(in: away) == (1, 5), "and it still counts meanwhile")
    }
}
