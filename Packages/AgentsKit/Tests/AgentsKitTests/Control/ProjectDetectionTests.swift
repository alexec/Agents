import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// Projects suggested on a host, never added by themselves (#429, #656).
@Suite("Project detection on a host")
struct ProjectDetectionTests {
    let caller = ControlRouter.Caller(session: UUID(), client: UUID(), kind: .mac)

    func methods() async throws -> (ControlMethods, ControlRecords) {
        let records = ControlRecords(store: MemoryStore())
        let settings = try await records.settings(orMake: { ControlSettings(name: "test", machineID: "m") })
        return (ControlMethods(records: records, settings: settings, version: "1"), records)
    }

    @Test func noHostIsMarkedToAddProjectsByItself() async throws {
        let (methods, records) = try await methods()
        try await methods.enroll(HostRecord(id: HostID(rawValue: "new00000"), name: "new"))
        #expect(await records.host(HostID(rawValue: "new00000"))?.detectProjects == nil)
    }

    @Test func aMarkFromBeforeGoesAtHelloAndTheHostIsNotTold() async throws {
        let (methods, records) = try await methods()
        let id = HostID(rawValue: "old00000")
        var old = HostRecord(id: id, name: "old")
        old.detectProjects = true
        try await records.save(old)
        _ = try await methods.hostSaid(id, method: DaemonAPI.Method.hostHello,
                                       params: try JSONValue.encoding(DaemonAPI.HostHello(version: "2", platform: "Linux x86-64", machineID: "srv")))
        #expect(await records.host(id)?.detectProjects == nil)
    }

    @Test func theSettingIsKeptAndSaid() async throws {
        let (methods, records) = try await methods()
        let status = try await methods.handle(method: DaemonAPI.Method.controlStatus, params: nil, from: caller)
            .decode(DaemonAPI.ControlStatus.self)
        #expect(status.projectDetection == .standard)
        #expect(ProjectDetection.standard.paths.first == "~")

        let off = ProjectDetection(enabled: false, paths: ["~/work", "  "])
        _ = try await methods.handle(method: DaemonAPI.Method.controlSetProjectDetection,
                                     params: try JSONValue.encoding(off), from: caller)
        #expect(await methods.detection == ProjectDetection(enabled: false, paths: ["~/work"]))
        #expect(await records.settings?.projectDetection?.paths == ["~/work"])
    }

    /// `projects/find` (#656): what is there to pick, and nothing added.
    @Test func findingListsRepositoriesAndTypedFoldersAndAddsNothing() async throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "find-\(UUID())")
        defer { try? FileManager.default.removeItem(at: home) }
        let files = FileManager.default
        for folder in ["src/app/.git", "src/tool/.git", "work/plain", "store"] {
            try files.createDirectory(at: home.appending(path: folder), withIntermediateDirectories: true)
        }
        let locations = StoreLocations(root: home.appending(path: "store", directoryHint: .isDirectory))
        let core = DaemonCore(store: try AgentStore(locations: locations), locations: locations,
                              discovery: .findsEverything, launcher: FakeLauncher(script: FakeACPAgent.Script()))
        await core.loadFromDisk()
        let tool = Project.standardize(home.appending(path: "src/tool", directoryHint: .isDirectory))
        _ = try await core.addProject(tool)

        let found = await core.findProjects(.init(paths: ["~/src"], folders: ["~/work/plain", "~/src/app", "~/gone", " "]),
                                            home: home)
        #expect(found.map(\.folder.lastPathComponent) == ["app", "tool", "plain", "app", "gone"])
        #expect(found.map(\.isProject) == [false, true, false, false, false])
        #expect(found.map(\.isRepository) == [true, true, false, true, false])
        #expect(found.map(\.exists) == [true, true, true, true, false])
        #expect(found.map(\.typed) == [nil, nil, "~/work/plain", "~/src/app", "~/gone"])
        let app = Project.standardize(home.appending(path: "src/app", directoryHint: .isDirectory))
        #expect(await core.projectRecords()[app] == nil)
    }

    @Test func aProjectIsAFolderOneLevelDownWithGitInIt() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "detect-\(UUID())")
        defer { try? FileManager.default.removeItem(at: home) }
        let files = FileManager.default
        for folder in ["app/.git", "src/tool/.git", "src/tool/deeper/.git", "src/notes", ".dotfiles/.git", "src/deep/one/.git"] {
            try files.createDirectory(at: home.appending(path: folder), withIntermediateDirectories: true)
        }
        // A worktree's `.git` is a file.
        try files.createDirectory(at: home.appending(path: "src/worktree"), withIntermediateDirectories: true)
        try Data("gitdir: elsewhere".utf8).write(to: home.appending(path: "src/worktree/.git"))

        let found = DaemonCore.found(["~", "~/src", "~/missing", "~/src"], home: home).map(\.lastPathComponent)
        #expect(found == ["app", "tool", "worktree"])
    }

    @Test func aTildeIsTheHostsHome() {
        let home = URL(filePath: "/home/agents", directoryHint: .isDirectory)
        #expect(DaemonCore.expand("~", home: home).path == "/home/agents")
        #expect(DaemonCore.expand(" ~/src ", home: home).path == "/home/agents/src")
        #expect(DaemonCore.expand("/srv/code", home: home).path == "/srv/code")
    }
}
