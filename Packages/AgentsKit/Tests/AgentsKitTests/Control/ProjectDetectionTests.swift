import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// Projects found once, when a host is added (#429).
@Suite("Project detection when a host is added")
struct ProjectDetectionTests {
    let caller = ControlRouter.Caller(session: UUID(), client: UUID(), kind: .mac)

    func methods() async throws -> (ControlMethods, ControlRecords) {
        let records = ControlRecords(store: MemoryStore())
        let settings = try await records.settings(orMake: { ControlSettings(name: "test", machineID: "m") })
        return (ControlMethods(records: records, settings: settings, version: "1"), records)
    }

    @Test func aNewHostIsMarkedAndOneAlreadyThereIsNot() async throws {
        let (methods, records) = try await methods()
        let old = HostRecord(id: HostID(rawValue: "old00000"), name: "old")
        try await records.save(old)
        try await methods.enroll(old)
        try await methods.enroll(HostRecord(id: HostID(rawValue: "new00000"), name: "new"))
        try await methods.enroll(HostRecord(id: HostID(rawValue: "relay000"), name: "relay", relay: true))
        #expect(await records.host(HostID(rawValue: "old00000"))?.detectProjects == nil)
        #expect(await records.host(HostID(rawValue: "new00000"))?.detectProjects == true)
        #expect(await records.host(HostID(rawValue: "relay000"))?.detectProjects == nil)
    }

    @Test func sayingItIsDoneClearsTheMarkForGood() async throws {
        let (methods, records) = try await methods()
        let id = HostID(rawValue: "new00000")
        try await methods.enroll(HostRecord(id: id, name: "new"))
        _ = try await methods.hostSaid(id, method: DaemonAPI.Method.projectsDetected, params: ["added": 3])
        #expect(await records.host(id)?.detectProjects == nil)
        // A hello afterwards (a reconnect) changes nothing: it is never asked again.
        _ = try await methods.hostSaid(id, method: DaemonAPI.Method.hostHello,
                                       params: try JSONValue.encoding(DaemonAPI.HostHello(version: "2", platform: "Linux x86-64", machineID: "srv")))
        #expect(await records.host(id)?.detectProjects == nil)
    }

    @Test func theSettingIsKeptAndSaidAndOffMarksNoOne() async throws {
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
        try await methods.enroll(HostRecord(id: HostID(rawValue: "new00000"), name: "new"))
        #expect(await records.host(HostID(rawValue: "new00000"))?.detectProjects == nil)
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
