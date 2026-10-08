import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// Deny: not on this host, without archiving it everywhere (#391).
///
/// The third answer to a workflow waiting for an OK. It is kept where Approve is, in
/// this host's records rather than the file, so the file and every other host are
/// untouched; it is of the file as it was shown, so a later change waits again; and
/// Approve takes it back.
@Suite("Denying a workflow on this host", .timeLimit(.minutes(1)))
struct WorkflowDenyTests {
    private func temporary(_ name: String = "host") throws -> (StoreLocations, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsDeny-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (StoreLocations(root: root), root.resolvingSymlinksInPath())
    }

    private func project(_ root: URL) throws -> URL {
        let url = root.appendingPathComponent("api", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return Project.standardize(url)
    }

    private func write(_ prompt: String, as workflowID: String, in project: URL) throws {
        try FileManager.default.createDirectory(at: WorkflowFile.folder(in: project), withIntermediateDirectories: true)
        try Data("---\non:\n  - schedule:\n      at: [\":00\"]\nagent: new\n---\n\n\(prompt)\n".utf8)
            .write(to: WorkflowFile.url(for: workflowID, in: project))
    }

    private func core(_ locations: StoreLocations, _ work: URL) async throws -> DaemonCore {
        let core = DaemonCore(store: try AgentStore(locations: locations), locations: locations,
                              discovery: .findsEverything, launcher: FakeLauncher())
        await core.loadFromDisk()
        await core.rescanWorkflows(in: work)
        await core.startWorkflows()
        return core
    }

    private func summary(_ core: DaemonCore, _ id: String, in work: URL) async throws -> WorkflowSummary {
        await core.rescanWorkflows(in: work)
        return try #require(await core.allWorkflows(in: work).first { $0.workflowID == id })
    }

    /// Approval has begun with `tests` approved; `deploy` arrives after and waits.
    private func waiting() async throws -> (DaemonCore, URL, StoreLocations) {
        let (locations, root) = try temporary()
        let work = try project(root)
        try write("Run the tests.", as: "tests", in: work)
        let core = try await core(locations, work)
        try write("Push to production.", as: "deploy", in: work)
        return (core, work, locations)
    }

    private func deny(_ core: DaemonCore, _ id: String, in work: URL) async throws -> WorkflowSummary {
        let digest = try #require(try await summary(core, id, in: work).awaitingApproval?.digest)
        return try await core.denyWorkflow(.init(folder: work, workflowID: id, digest: digest))
    }

    @Test func aDeniedWorkflowStaysListedAndStopsWaiting() async throws {
        let (core, work, _) = try await waiting()
        let file = WorkflowFile.url(for: "deploy", in: work)
        let before = try Data(contentsOf: file)

        let denied = try await deny(core, "deploy", in: work)

        #expect(denied.deniedHere != nil)
        #expect(denied.awaitingApproval == nil, "an answer, so no longer waiting")
        #expect(!denied.isArchived, "it stays in its place, not under Archived")
        #expect(!denied.needsAPerson)
        #expect(denied.canBeApproved, "Approve is still there to take it back")
        #expect(!denied.canBeDenied)
        #expect(denied.nextFireAt == nil)
        #expect(try Data(contentsOf: file) == before, "nothing is written into the file")
    }

    @Test func neitherRunNowNorATriggerRunsItHere() async throws {
        let (core, work, _) = try await waiting()
        _ = try await deny(core, "deploy", in: work)

        let ran = try await core.runWorkflow(.init(folder: work, workflowID: "deploy"))
        #expect(await core.allAgents().isEmpty, "Run now started nothing")
        if case .refused(.deniedHere, _, _) = ran.lastOutcome {} else {
            Issue.record("expected a refusal for being denied, got \(String(describing: ran.lastOutcome))")
        }

        let workflow = try #require(await core.workflow("deploy", in: work))
        let trigger = try #require(workflow.triggers.first)
        let refusal = await core.fire(workflow, on: trigger)
        #expect(refusal == .deniedHere)
        #expect(await core.allAgents().isEmpty, "its trigger started nothing")
    }

    @Test func anotherHostStillSeesItWaiting() async throws {
        let (locations, root) = try temporary()
        let work = try project(root)
        try write("Run the tests.", as: "tests", in: work)
        let here = try await core(locations, work)
        let (otherLocations, _) = try temporary("other")
        let other = try await core(otherLocations, work)
        try write("Push to production.", as: "deploy", in: work)

        _ = try await deny(here, "deploy", in: work)

        let there = try await summary(other, "deploy", in: work)
        #expect(there.awaitingApproval?.isNew == true)
        #expect(there.deniedHere == nil)
        let approved = try await other.approveWorkflow(
            .init(folder: work, workflowID: "deploy", digest: try #require(there.awaitingApproval).digest))
        #expect(approved.awaitingApproval == nil, "another host can approve it and run it")
        #expect(try await summary(here, "deploy", in: work).deniedHere != nil, "still denied here")
    }

    @Test func approveTakesTheDenialBack() async throws {
        let (core, work, _) = try await waiting()
        let denied = try await deny(core, "deploy", in: work)

        let approved = try await core.approveWorkflow(
            .init(folder: work, workflowID: "deploy", digest: try #require(denied.approvable).digest))

        #expect(approved.deniedHere == nil && approved.awaitingApproval == nil)
        _ = try await core.runWorkflow(.init(folder: work, workflowID: "deploy"))
        #expect(await core.allAgents().count == 1)
    }

    @Test func aChangedFileWaitsAgain() async throws {
        let (core, work, _) = try await waiting()
        _ = try await deny(core, "deploy", in: work)

        try write("Push to production, then tag.", as: "deploy", in: work)

        let changed = try await summary(core, "deploy", in: work)
        #expect(changed.deniedHere == nil)
        #expect(changed.awaitingApproval?.isNew == true)
    }

    @Test func onlyTheFileThatWasShownIsDenied() async throws {
        let (core, work, _) = try await waiting()
        let shown = try #require(try await summary(core, "deploy", in: work).awaitingApproval?.digest)
        try write("Push to production, then tag.", as: "deploy", in: work)

        await #expect(throws: JSONRPCError.self) {
            _ = try await core.denyWorkflow(.init(folder: work, workflowID: "deploy", digest: shown))
        }
        #expect(try await summary(core, "deploy", in: work).awaitingApproval != nil)
    }

    @Test func theDenialOutlivesARestart() async throws {
        let (first, work, locations) = try await waiting()
        _ = try await deny(first, "deploy", in: work)

        let second = try await core(locations, work)
        #expect(try await summary(second, "deploy", in: work).deniedHere != nil)
    }

    @Test func denyingFreesAPlaceAmongTheWaiting() async throws {
        let (locations, root) = try temporary()
        let work = try project(root)
        try write("Go.", as: "p1", in: work)
        let core = try await core(locations, work)
        for name in ["a-new", "b-new", "c-new", "d-new"] { try write("Go.", as: name, in: work) }
        #expect(try await summary(core, "d-new", in: work).waitsItsTurn)

        _ = try await deny(core, "a-new", in: work)

        let next = try await summary(core, "d-new", in: work)
        #expect(!next.waitsItsTurn && next.canBeApproved)
    }

    @Test func aDeniedWorkflowDoesNotCountTowardsTheTen() async throws {
        let (locations, root) = try temporary()
        let work = try project(root)
        let names = (1...11).map { String(format: "w%02d", $0) }
        for name in names { try write("Go.", as: name, in: work) }
        let core = try await core(locations, work)
        #expect(try await summary(core, "w11", in: work).overLimit == .total)

        let first = try #require(await core.workflow("w01", in: work))
        let shown = try #require(await core.workflowDigest(first))
        let denied = try await core.denyWorkflow(.init(folder: work, workflowID: "w01", digest: shown))

        #expect(denied.overLimit == nil)
        #expect(try await summary(core, "w11", in: work).overLimit == nil)
    }
}
