import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// A project's one watch (#173): what it hears, and what it leaves alone.
///
/// The daemon held two FSEvents streams per project, each with a descriptor on every
/// folder above it, and woke for every file a build wrote under `.agents/worktrees`.
@Suite("Watching a project", .timeLimit(.minutes(1)))
struct ProjectWatchTests {
    private func temporary() throws -> (StoreLocations, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsProjectWatch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (StoreLocations(root: root), root.resolvingSymlinksInPath())
    }

    private func write(_ workflowID: String, in project: URL) throws {
        try Self.write(workflowID, in: project)
    }

    private func project(_ root: URL) throws -> URL {
        let url = root.appendingPathComponent("api", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return Project.standardize(url)
    }

    private static func write(_ workflowID: String, in project: URL) throws {
        let folder = WorkflowFile.folder(in: project)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("""
            ---
            on:
              - schedule:
                  at: [":00"]
            ---

            Go.
            """.utf8).write(to: WorkflowFile.url(for: workflowID, in: project))
    }

    private func core(_ locations: StoreLocations) async throws -> DaemonCore {
        let store = try AgentStore(locations: locations)
        let core = DaemonCore(store: store, locations: locations,
                              discovery: .findsEverything,
                              launcher: FakeLauncher(script: FakeACPAgent.Script()))
        await core.loadFromDisk()
        return core
    }

    /// The watch is listening: FSEvents offers nothing to wait on, so a workflow is
    /// written until one is read.
    private func warmUp(_ core: DaemonCore, _ work: URL) async throws {
        await eventually("the project's watch is up") {
            try? Self.write("warm-up-\(UUID().uuidString)", in: work)
            return await core.allWorkflows(in: work).contains { $0.workflowID.hasPrefix("warm-up") }
        }
    }

    @Test func aWorkflowWrittenByHandIsReadWithinTheDebounce() async throws {
        let (locations, root) = try temporary()
        let work = try project(root)
        let core = try await core(locations)
        _ = try await core.addProject(work)
        try await warmUp(core, work)

        let start = ContinuousClock.now
        try write("by-hand", in: work)
        // FSEvents' 0.2 s and the rescan's 0.25 s, with room for a busy machine.
        let deadline = start.advanced(by: .seconds(3))
        while ContinuousClock.now < deadline,
              await !core.allWorkflows(in: work).contains(where: { $0.workflowID == "by-hand" }) {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(await core.allWorkflows(in: work).contains { $0.workflowID == "by-hand" },
                "not read within 3 s")
    }

    @Test func aBuildInAWorktreeOrItsOutputDoesNotWakeTheDaemon() async throws {
        let (locations, root) = try temporary()
        let work = try project(root)
        let lane = work.appending(path: ".agents/worktrees/lane")
        let outputs = [lane.appending(path: ".build/debug"), lane.appending(path: "src"),
                       work.appending(path: "node_modules/pkg"), work.appending(path: ".build/debug"),
                       work.appending(path: "Web/node_modules/pkg")]
        // There before the watch starts, as a project's build folders are.
        for folder in outputs { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let core = try await core(locations)
        _ = try await core.addProject(work)
        try await warmUp(core, work)
        // Whatever the warm-up stirred has been heard before counting starts.
        try await Task.sleep(for: .milliseconds(600))
        let before = await core.projectWatchWakes

        for round in 0..<10 {
            for folder in outputs {
                for file in 0..<20 { try Data("\(round)".utf8).write(to: folder.appending(path: "f\(file).o")) }
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        // An absence, so time passing is the assertion.
        try await Task.sleep(for: .milliseconds(800))
        #expect(await core.projectWatchWakes == before, "a build woke the project's watch")

        // And the watch is still up: a change it does read still arrives.
        try write("after-the-build", in: work)
        await eventually("the workflow is read") {
            await core.allWorkflows(in: work).contains { $0.workflowID == "after-the-build" }
        }
        await core.stopWatchingAllWorkflows()
    }

    @Test func aFolderHoldingAPinnedPageStaysWatched() async throws {
        let (locations, root) = try temporary()
        let work = try project(root)
        let core = try await core(locations)
        #expect(await core.projectWatchExclusions(work).contains { $0.lastPathComponent == "dist" })

        try FileManager.default.createDirectory(at: work.appending(path: "dist"), withIntermediateDirectories: true)
        try Data("<p>hi</p>".utf8).write(to: work.appending(path: "dist/index.html"))
        try await core.writePins(PinsFile(pins: [PinEntry(path: "dist/index.html", pinnedBy: Pinner(person: true))]),
                                 in: work)

        let excluded = await core.projectWatchExclusions(work).map(\.lastPathComponent)
        #expect(!excluded.contains("dist"))
        #expect(excluded.first == "worktrees")
        #expect(excluded.count <= FolderWatch.maximumExclusions)
    }

    @Test func theDashboardKeepsItsPointsAcrossItsOwnWrite() throws {
        let (locations, root) = try temporary()
        let work = try project(root)
        let store = DashboardStore(locations: locations)
        try store.record(1, at: Date(timeIntervalSince1970: 1_000_000), for: "builds", in: work)
        try store.record(2, at: Date(timeIntervalSince1970: 1_100_000), for: "builds", in: work)
        // The watch hears that write and asks the store to forget what changed.
        store.forgetPoints(work)
        #expect(store.points(work, "builds").map(\.value) == [1, 2])

        // A pull rewrites the file: that one is read again.
        let file = DashboardStore.historyFolder(work).appending(path: "builds.jsonl")
        try Data("{\"t\":1000000,\"v\":1}\n{\"t\":1100000,\"v\":3}\n".utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: file.path)
        store.forgetPoints(work)
        #expect(store.points(work, "builds").map(\.value) == [1, 3])
    }
}
