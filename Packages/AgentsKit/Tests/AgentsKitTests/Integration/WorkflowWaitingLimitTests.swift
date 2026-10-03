import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// A project may have at most three workflows waiting for approval, and any number
/// approved (#132).
///
/// The worry the ceiling answers is a queue of files nobody reviewed, so only those
/// count. A file past the three — one a merge brought, say — is listed and inert, says
/// why, and cannot be approved until one ahead of it is approved, archived or removed.
@Suite("Three waiting for approval", .timeLimit(.minutes(1)))
struct WorkflowWaitingLimitTests {
    private func temporary() throws -> (StoreLocations, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsWaitingLimit-\(UUID().uuidString)", isDirectory: true)
        let work = root.appendingPathComponent("api", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        return (StoreLocations(root: root), Project.standardize(work))
    }

    private func write(_ workflowID: String, in project: URL, saying prompt: String = "Go.") throws {
        try FileManager.default.createDirectory(at: WorkflowFile.folder(in: project), withIntermediateDirectories: true)
        try Data("---\non:\n  - schedule:\n      at: [\":00\"]\nagent: new\n---\n\n\(prompt)\n".utf8)
            .write(to: WorkflowFile.url(for: workflowID, in: project))
    }

    private func core(_ locations: StoreLocations) async throws -> DaemonCore {
        let core = DaemonCore(store: try AgentStore(locations: locations), locations: locations,
                              discovery: .findsEverything, launcher: FakeLauncher())
        await core.loadFromDisk()
        return core
    }

    private func summary(_ core: DaemonCore, _ work: URL, _ id: String) async throws -> WorkflowSummary {
        try #require(await core.allWorkflows(in: work).first { $0.workflowID == id })
    }

    private func approve(_ core: DaemonCore, _ work: URL, _ id: String) async throws {
        let digest = try #require(try await summary(core, work, id).awaitingApproval?.digest)
        _ = try await core.approveWorkflow(.init(folder: work, workflowID: id, digest: digest))
    }

    /// Five approved when approval began, then four new files on disk: the first
    /// three by name may wait, `d-new` waits its turn.
    private func fourWaiting() async throws -> (DaemonCore, URL) {
        let (locations, work) = try temporary()
        for name in ["p1", "p2", "p3", "p4", "p5"] { try write(name, in: work) }
        let core = try await core(locations)
        await core.rescanWorkflows(in: work)
        await core.startWorkflows()
        for name in ["a-new", "b-new", "c-new", "d-new"] { try write(name, in: work) }
        await core.rescanWorkflows(in: work)
        return (core, work)
    }

    @Test func approvedOnesDoNotCountAndAllRun() async throws {
        let (core, work) = try await fourWaiting()

        for name in ["p1", "p2", "p3", "p4", "p5"] {
            let approved = try await summary(core, work, name)
            #expect(approved.awaitingApproval == nil)
            #expect(approved.overLimit == nil)
            _ = try await core.runWorkflow(.init(folder: work, workflowID: name))
        }
        #expect(await core.allAgents().count == 5)
    }

    @Test func aFourthWaitingFileIsListedInertAndSaysWhy() async throws {
        let (core, work) = try await fourWaiting()

        for name in ["a-new", "b-new", "c-new"] {
            let waiting = try await summary(core, work, name)
            #expect(waiting.canBeApproved)
            #expect(waiting.overLimit == nil)
        }
        let fourth = try await summary(core, work, "d-new")
        #expect(fourth.awaitingApproval != nil)
        #expect(fourth.overLimit == .project)
        #expect(fourth.waitsItsTurn)
        #expect(!fourth.canBeApproved)
        #expect(fourth.needsAPerson)
        #expect(fourth.nextFireAt == nil)
    }

    @Test func approvingTheFourthIsRefusedWithTheMessage() async throws {
        let (core, work) = try await fourWaiting()
        let digest = try #require(try await summary(core, work, "d-new").awaitingApproval?.digest)

        do {
            _ = try await core.approveWorkflow(.init(folder: work, workflowID: "d-new", digest: digest))
            Issue.record("the fourth waiting workflow was approved")
        } catch let error as JSONRPCError {
            #expect(error.code == DaemonAPI.Failure.workflowLimitReached)
            #expect(error.message.contains("Approve or remove one of the 3 workflows waiting for approval first."))
        }
        #expect(try await summary(core, work, "d-new").awaitingApproval != nil)
    }

    @Test func theMessageIsTheOneAgreedOn() {
        #expect(WorkflowLimit.project.remedy + "."
                == "Approve or remove one of the 3 workflows waiting for approval first.")
        #expect(WorkflowLimit.total.allowed == 10)
    }

    @Test func approvingOneFreesAPlace() async throws {
        let (core, work) = try await fourWaiting()
        try await approve(core, work, "a-new")

        let fourth = try await summary(core, work, "d-new")
        #expect(fourth.overLimit == nil)
        #expect(fourth.canBeApproved)
        try await approve(core, work, "d-new")
        #expect(try await summary(core, work, "d-new").awaitingApproval == nil)
    }

    @Test func archivingOneFreesAPlace() async throws {
        let (core, work) = try await fourWaiting()
        _ = try await core.archiveWorkflow(.init(folder: work, workflowID: "b-new", archived: true))

        #expect(try await summary(core, work, "d-new").canBeApproved)
    }

    @Test func removingOneFreesAPlace() async throws {
        let (core, work) = try await fourWaiting()
        try FileManager.default.removeItem(at: WorkflowFile.url(for: "c-new", in: work))
        await core.rescanWorkflows(in: work)

        #expect(try await summary(core, work, "d-new").canBeApproved)
    }

    @Test func aChangedApprovedFileWaitsInTheSameQueue() async throws {
        // An approved file edited outside the app waits again, and takes a place like
        // a new one: by name, so `a-new`..`c-new` keep theirs and `p1` sorts after them.
        let (core, work) = try await fourWaiting()
        try write("p1", in: work, saying: "Go further.")
        await core.rescanWorkflows(in: work)

        #expect(try await summary(core, work, "p1").overLimit == .project)
        #expect(try await summary(core, work, "p2").overLimit == nil)
    }
}
