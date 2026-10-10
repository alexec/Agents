import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// `runs` in `workflows.json`: the workflow runs in flight when the daemon went.
///
/// The one thing this file must never do is cost what was already in it. It holds which
/// workflows the person archived and which agent each standing workflow keeps, and
/// `WorkflowStore.load()` reads a file it cannot decode as empty — so a new field that
/// made old files undecodable would quietly un-archive every workflow the person put
/// away. That is why the first test here is about a file with no `runs` in it at all.
@Suite("Workflow runs on disk")
struct WorkflowRunStoreTests {
    private func temporary() -> StoreLocations {
        StoreLocations(root: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsWorkflowRuns-\(UUID().uuidString)", isDirectory: true))
    }

    private func run(_ workflowID: String = "morning-tests", depth: Int = 1) -> WorkflowRun {
        WorkflowRun(workflowID: workflowID,
                    folder: URL(filePath: "/tmp/somewhere/api"),
                    trigger: .event(EventPattern("workflow.completed", filters: ["workflow": DetailFilter("nightly")])),
                    triggeringAgentID: UUID(),
                    depth: depth,
                    agentID: UUID(),
                    startedAt: Date(timeIntervalSince1970: 1_790_000_000))
    }

    /// A file written before runs were kept still reads, and keeps what it said. This is
    /// the test that stops a new field from costing every archived workflow.
    @Test func aFileWrittenBeforeRunsWereKeptStillReads() throws {
        let locations = temporary()
        defer { try? FileManager.default.removeItem(at: locations.root) }
        try FileManager.default.createDirectory(at: locations.root, withIntermediateDirectories: true)
        try Data("""
            {"lastTickAt":"2026-09-24T09:00:00.000Z",
             "states":[{"folder":"file:///tmp/somewhere/api","isArchived":true,"workflowID":"nightly"}]}
            """.utf8).write(to: locations.workflows)

        let read = WorkflowStore(locations: locations).load()

        #expect(read.states.count == 1, "the archived workflow is still archived")
        #expect(read.states.first?.legacy?.isArchived == true, "kept until it is written into the file")
        #expect(read.lastTickAt != nil)
        #expect(read.runs.isEmpty)
    }

    /// Everything a run carries comes back, and the states beside it are untouched.
    @Test func aRunInFlightComesBack() throws {
        let locations = temporary()
        defer { try? FileManager.default.removeItem(at: locations.root) }
        let store = WorkflowStore(locations: locations)
        let written = run()
        var records = WorkflowRecords()
        records.update(folder: written.folder, workflowID: "nightly") { $0.approvedDigest = "abc" }
        records.runs = [written]

        try store.save(records)
        let read = store.load()

        #expect(read.runs == [written])
        #expect(read.runs.first?.depth == 1, "the depth is what the chain ceiling counts from")
        #expect(read.state(folder: written.folder, workflowID: "nightly")?.approvedDigest == "abc")
    }

    /// One run that will not decode costs that run, not the file — and certainly not the
    /// approvals beside it.
    @Test func oneBadRunCostsThatRunAndNothingElse() throws {
        let locations = temporary()
        defer { try? FileManager.default.removeItem(at: locations.root) }
        let store = WorkflowStore(locations: locations)
        var records = WorkflowRecords()
        records.update(folder: URL(filePath: "/tmp/somewhere/api"), workflowID: "nightly") {
            $0.approvedDigest = "abc"
        }
        records.runs = [run("good")]
        try store.save(records)

        // Break one run by hand, the way a future build's field might.
        var text = try String(contentsOf: locations.workflows, encoding: .utf8)
        text = text.replacingOccurrences(of: "\"runs\":[", with: "\"runs\":[{\"what\":\"is this\"},")
        try Data(text.utf8).write(to: locations.workflows)

        let read = store.load()
        #expect(read.runs.map(\.workflowID) == ["good"])
        #expect(read.states.first?.approvedDigest == "abc")
    }

    /// Every writer of this file reads it whole and writes it whole, so a run survives a
    /// write that is about something else — the tick, or an outcome.
    @Test func aRunSurvivesAWriteThatIsAboutSomethingElse() throws {
        let locations = temporary()
        defer { try? FileManager.default.removeItem(at: locations.root) }
        let store = WorkflowStore(locations: locations)
        var records = WorkflowRecords()
        records.runs = [run()]
        try store.save(records)

        var again = store.load()
        again.lastTickAt = Date()
        again.record(.refused(.runInFlight, at: Date(), repeats: 1),
                     folder: URL(filePath: "/tmp/somewhere/api"), workflowID: "other")
        try store.save(again)

        #expect(store.load().runs.count == 1)
    }
}
