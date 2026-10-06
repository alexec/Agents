import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// A workflow runs on the computers its file names, and nowhere else (#317).
@Suite("A workflow runs on the hosts it names", .timeLimit(.minutes(1)))
struct WorkflowHostTests {
    private func temporary() throws -> (StoreLocations, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsWorkflowHosts-\(UUID().uuidString)", isDirectory: true)
        let work = root.appendingPathComponent("api", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        return (StoreLocations(root: root), Project.standardize(work))
    }

    @discardableResult
    private func write(_ text: String, as workflowID: String, in project: URL) throws -> URL {
        let folder = WorkflowFile.folder(in: project)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = WorkflowFile.url(for: workflowID, in: project)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func core(_ locations: StoreLocations) async throws -> DaemonCore {
        let core = DaemonCore(store: try AgentStore(locations: locations), locations: locations,
                              discovery: .findsEverything, launcher: FakeLauncher())
        await core.loadFromDisk()
        return core
    }

    private var nineOClock: Date {
        var when = DateComponents()
        when.year = 2026; when.month = 9; when.day = 18; when.hour = 8; when.minute = 59
        return Calendar.current.date(from: when)!
    }

    private var here: String { MachineID.current }

    @Test func aWorkflowWithNoHostsShowsAndRunsHereAndOneNamedForHereDoesToo() async throws {
        let (locations, work) = try temporary()
        let open = try write("""
            ---
            on: agent-finished
            claim: one
            ---

            Go.
            """, as: "open", in: work)
        try write("""
            ---
            on: agent-finished
            hosts:
              - \(here)
            ---

            Go.
            """, as: "here", in: work)
        try write("""
            ---
            on: agent-finished
            hosts:
              - some-other-computer
            ---

            Go.
            """, as: "there", in: work)
        try write("""
            ---
            on:
              - schedule:
                  at: [":00", ":30"]
            hosts:
              - some-other-computer
            agent: new
            ---

            Go.
            """, as: "nightly", in: work)

        let core = try await core(locations)
        await core.rescanWorkflows(in: work)
        let listed = await core.allWorkflows(in: work).map(\.workflowID)
        #expect(listed == ["here", "open"])

        _ = try await core.runWorkflow(DaemonAPI.WorkflowRequest(folder: work, workflowID: "open"))
        _ = try await core.runWorkflow(DaemonAPI.WorkflowRequest(folder: work, workflowID: "here"))
        #expect(await core.allAgents().count == 2)

        do {
            _ = try await core.runWorkflow(DaemonAPI.WorkflowRequest(folder: work, workflowID: "there"))
            Issue.record("a workflow for another computer ran here")
        } catch let error as JSONRPCError {
            #expect(error.code == DaemonAPI.Failure.noSuchWorkflow)
            #expect(error.message.contains("runs on another computer"))
        }
        #expect(await core.allAgents().count == 2)

        await core.tickWorkflows(now: nineOClock)
        await core.tickWorkflows(now: nineOClock.addingTimeInterval(60))
        #expect(await core.allAgents().count == 2, "a schedule for another computer starts nothing here")

        let foreign = try #require(await core.workflow("there", in: work))
        _ = await core.fire(foreign, on: .agentStopped)
        #expect(await core.allAgents().count == 2, "an event for another computer starts nothing here")

        let before = try String(contentsOf: open, encoding: .utf8)
        let pinned = try #require(await core.allWorkflows(in: work).first { $0.workflowID == "open" })
        let away = try await core.setWorkflowSettings(DaemonAPI.WorkflowSettingsRequest(
            folder: work, workflowID: "open", settings: pinned.workflow.settings, hosts: ["some-other-computer"]))
        #expect(away.workflow.hosts == ["some-other-computer"])
        #expect(await core.allWorkflows(in: work).map(\.workflowID) == ["here"])
        let pinnedText = try String(contentsOf: open, encoding: .utf8)
        #expect(pinnedText.contains("hosts:"))
        #expect(pinnedText.contains("claim: one"))
        let read = WorkflowFile.parse(pinnedText, workflowID: "open", in: work)
        #expect(read.unknownFields["claim"] == .string("one"))
        #expect(read.hosts == ["some-other-computer"])
        #expect(before.contains("claim: one"))

        _ = try await core.setWorkflowSettings(DaemonAPI.WorkflowSettingsRequest(
            folder: work, workflowID: "open", settings: pinned.workflow.settings, hosts: []))
        #expect(await core.allWorkflows(in: work).map(\.workflowID).sorted() == ["here", "open"])
        let restored = try String(contentsOf: open, encoding: .utf8)
        #expect(!restored.contains("hosts:"))
        #expect(restored.contains("claim: one"))
    }

    @Test func aSingleIdOnOneLineIsRewrittenAsAListWhenThePageChangesIt() async throws {
        let (locations, work) = try temporary()
        let url = try write("""
            ---
            on: agent-finished
            hosts: some-other-computer
            claim: one
            ---

            Go.
            """, as: "pinned", in: work)
        let core = try await core(locations)
        await core.rescanWorkflows(in: work)
        #expect(await core.allWorkflows(in: work).isEmpty)

        let read = try #require(await core.workflow("pinned", in: work))
        let brought = try await core.setWorkflowSettings(DaemonAPI.WorkflowSettingsRequest(
            folder: work, workflowID: "pinned", settings: read.settings, hosts: [here]))
        #expect(brought.workflow.hosts == [here])
        #expect(await core.allWorkflows(in: work).map(\.workflowID) == ["pinned"])
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains(here))
        #expect(text.contains("claim: one"))
        #expect(!text.contains("hosts: some-other-computer"))
    }
}
