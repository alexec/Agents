import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// A drop box per project (#231): a file arriving in `.agents/dropbox/` raises
/// `dropbox.file_added` once, and a workflow can run on it.
@Suite("A project's drop box", .timeLimit(.minutes(1)))
struct DropboxTests {
    private func temporary() throws -> (StoreLocations, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsDropbox-\(UUID().uuidString)", isDirectory: true)
        let work = root.appendingPathComponent("api", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        return (StoreLocations(root: root), Project.standardize(work))
    }

    private func core(_ locations: StoreLocations) async throws -> DaemonCore {
        let core = DaemonCore(store: try AgentStore(locations: locations), locations: locations,
                              discovery: .findsEverything, launcher: FakeLauncher())
        await core.loadFromDisk()
        return core
    }

    private static func writeWorkflow(_ text: String, as workflowID: String, in project: URL) throws {
        let folder = WorkflowFile.folder(in: project)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: WorkflowFile.url(for: workflowID, in: project))
    }

    /// The watch is listening: FSEvents offers nothing to wait on, so a workflow is
    /// written until one is read.
    private func warmUp(_ core: DaemonCore, _ work: URL) async {
        await eventually("the project's watch is up") {
            try? Self.writeWorkflow("---\non:\n  - mac.wake\n---\n\nGo.\n",
                                    as: "warm-up-\(UUID().uuidString)", in: work)
            return await core.allWorkflows(in: work).contains { $0.workflowID.hasPrefix("warm-up") }
        }
    }

    private func drop(_ text: String, at relative: String, in work: URL) throws {
        let file = DaemonCore.dropboxFolder(in: work).appending(path: relative)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file, options: .atomic)
    }

    private func arrivals(_ core: DaemonCore) async -> [Event] {
        await core.eventLog.events.filter { $0.name == "dropbox.file_added" }
    }

    @Test func aNewFileFiresOnceAndOneAlreadyThereDoesNot() async throws {
        let (locations, work) = try temporary()
        try drop("old", at: "waiting.md", in: work)
        let core = try await core(locations)
        _ = try await core.addProject(work)
        await warmUp(core, work)

        try drop("hello", at: "review/report.PDF", in: work)
        await eventually("the arrival is raised", within: .seconds(10)) { await arrivals(core).count == 1 }
        let event = try #require(await arrivals(core).first)
        #expect(event.details["name"] == "report.PDF")
        #expect(event.details["folder"] == "review")
        #expect(event.details["extension"] == "pdf")
        #expect(event.details["size"] == "5")
        #expect(event.details["path"] == DaemonCore.dropboxFolder(in: work).appending(path: "review/report.PDF").path)
        #expect(event.scope == .project(folder: work))

        // Still, it is not raised again; the file already there never was.
        try await Task.sleep(for: .seconds(2))
        #expect(await arrivals(core).count == 1)
        #expect(await core.eventLog.events.allSatisfy { $0.details["name"] != "waiting.md" })

        // The same name again is a new arrival.
        try drop("hello again", at: "review/report.PDF", in: work)
        await eventually("the replacement is raised", within: .seconds(10)) { await arrivals(core).count == 2 }
        await core.stopWatchingAllWorkflows()
    }

    @Test func aFileStillBeingWrittenFiresOnceWhenItStops() async throws {
        let (locations, work) = try temporary()
        let core = try await core(locations)
        _ = try await core.addProject(work)
        await warmUp(core, work)

        let file = DaemonCore.dropboxFolder(in: work).appending(path: "slow.log")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        for _ in 0..<8 {
            try handle.write(contentsOf: Data("more\n".utf8))
            try await Task.sleep(for: .milliseconds(200))
        }
        try handle.close()
        await eventually("the arrival is raised", within: .seconds(10)) { await arrivals(core).count == 1 }
        try await Task.sleep(for: .seconds(2))
        let raised = await arrivals(core)
        #expect(raised.count == 1)
        #expect(raised.first?.details["size"] == "40")
        await core.stopWatchingAllWorkflows()
    }

    @Test func aWorkflowNarrowedToAFolderRunsOnlyForItAndIsToldThePath() async throws {
        let (locations, work) = try temporary()
        try Self.writeWorkflow("""
            ---
            on:
              - dropbox.file_added:
                  folder: review
                  extension: [pdf, md]
            agent: new
            ---

            Review it.
            """, as: "review", in: work)
        let core = try await core(locations)
        _ = try await core.addProject(work)
        await core.rescanWorkflows(in: work)
        await warmUp(core, work)
        #expect(await core.allWorkflows(in: work).first { $0.workflowID == "review" }?.workflow.problem == nil)

        try drop("top", at: "notes.md", in: work)
        try drop("wrong kind", at: "review/data.csv", in: work)
        await eventually("both arrivals are raised", within: .seconds(10)) { await arrivals(core).count == 2 }
        try await Task.sleep(for: .milliseconds(300))
        #expect(await core.allAgents().filter { $0.startedByWorkflow == "review" }.isEmpty)

        try drop("please", at: "review/draft.md", in: work)
        await eventually("the workflow started an agent", within: .seconds(10)) {
            await core.allAgents().contains { $0.startedByWorkflow == "review" }
        }
        let agent = try #require(await core.allAgents().first { $0.startedByWorkflow == "review" })
        let path = DaemonCore.dropboxFolder(in: work).appending(path: "review/draft.md").path
        let prompt = await eventuallySome("the prompt is on the record") { () async -> String? in
            let page = try? await core.transcript(.init(agentID: agent.id, before: nil, limit: 50))
            return page?.entries.lazy.compactMap { entry -> String? in
                if case .userMessage(let text, _, _) = entry.kind { return text }
                return nil
            }.first
        }
        #expect(prompt?.contains("dropbox.file_added") == true)
        #expect(prompt?.contains("path: \(path)") == true)
        await core.stopWatchingAllWorkflows()
    }

    @Test func putWritesIntoTheDropBoxAndTheWatchHearsIt() async throws {
        let (locations, work) = try temporary()
        let core = try await core(locations)
        _ = try await core.addProject(work)
        await warmUp(core, work)

        let put = try await core.putInDropbox(.init(folder: work, subfolder: "notes/today", name: "../idea.txt",
                                                    data: Data("an idea".utf8)))
        let expected = DaemonCore.dropboxFolder(in: work).appending(path: "notes/today/idea.txt").path
        #expect(put.path == expected)
        #expect(try String(contentsOfFile: expected, encoding: .utf8) == "an idea")
        await eventually("the arrival is raised", within: .seconds(10)) { await arrivals(core).count == 1 }
        #expect(await arrivals(core).first?.details["folder"] == "notes/today")
        // Nothing left behind from writing it.
        let left = try FileManager.default.contentsOfDirectory(atPath: (expected as NSString).deletingLastPathComponent)
        #expect(left == ["idea.txt"])

        await #expect(throws: JSONRPCError.self) {
            try await core.putInDropbox(.init(folder: work, name: ".hidden", data: Data()))
        }
        await #expect(throws: JSONRPCError.self) {
            try await core.putInDropbox(.init(folder: work, subfolder: "../..", name: "x", data: Data()))
        }
        await #expect(throws: JSONRPCError.self) {
            try await core.putInDropbox(.init(folder: work.deletingLastPathComponent(), name: "x", data: Data()))
        }
        await core.stopWatchingAllWorkflows()
    }
}
