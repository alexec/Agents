import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// A file that says `enabled: false` arrives turned off (#42).
///
/// The Enabled switch is the app's own state, never written to the file, so a workflow
/// checked in for somebody to turn on when they are ready needs the file to say where
/// the switch starts. Once anybody moves the switch, that choice is kept, as before.
@Suite("A workflow that starts off", .timeLimit(.minutes(1)))
struct WorkflowStartsOffTests {
    private func temporary() throws -> (StoreLocations, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsWorkflowStartsOff-\(UUID().uuidString)", isDirectory: true)
        let work = root.appendingPathComponent("api", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        return (StoreLocations(root: root), Project.standardize(work))
    }

    private func text(enabled: String?) -> String {
        "---\non:\n  - schedule:\n      at: [\":00\", \":30\"]\nagent: new\n"
            + (enabled.map { "enabled: \($0)\n" } ?? "") + "---\n\nGo.\n"
    }

    private func write(enabled: String?, as workflowID: String, in project: URL) throws {
        let folder = WorkflowFile.folder(in: project)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(text(enabled: enabled).utf8).write(to: WorkflowFile.url(for: workflowID, in: project))
    }

    private func core(_ locations: StoreLocations) async throws -> DaemonCore {
        let core = DaemonCore(store: try AgentStore(locations: locations), locations: locations,
                              discovery: .findsEverything, launcher: FakeLauncher(script: .init()))
        await core.loadFromDisk()
        return core
    }

    private func summary(_ core: DaemonCore, _ folder: URL, _ id: String) async -> WorkflowSummary? {
        await core.allWorkflows(in: folder).first { $0.workflowID == id }
    }

    private var nineOClock: Date {
        var when = DateComponents()
        when.year = 2026; when.month = 9; when.day = 18; when.hour = 8; when.minute = 59
        return Calendar.current.date(from: when)!
    }

    // MARK: The file

    @Test func theFileSaysWhereTheSwitchStarts() {
        let project = URL(fileURLWithPath: "/tmp/x")
        #expect(WorkflowFile.parse(text(enabled: "false"), workflowID: "w", in: project).enabled == false)
        #expect(WorkflowFile.parse(text(enabled: "true"), workflowID: "w", in: project).enabled == true)
        #expect(WorkflowFile.parse(text(enabled: nil), workflowID: "w", in: project).enabled == nil)
        let off = WorkflowFile.parse(text(enabled: "false"), workflowID: "w", in: project)
        #expect(off.problem == nil)
        #expect(off.unknownFields["enabled"] == nil, "a key this version knows is not kept as unknown")
    }

    @Test func anythingButTrueOrFalseIsAFileToFix() {
        let workflow = WorkflowFile.parse(text(enabled: "maybe"), workflowID: "w",
                                          in: URL(fileURLWithPath: "/tmp/x"))
        guard case .unreadable(let why) = workflow.problem else {
            Issue.record("expected the file to be unreadable, got \(String(describing: workflow.problem))")
            return
        }
        #expect(why.contains("enabled"))
    }

    // MARK: The daemon

    @Test func itArrivesOffAndTheClockDoesNotRunIt() async throws {
        let (locations, work) = try temporary()
        try write(enabled: "false", as: "weekly", in: work)
        let core = try await core(locations)
        await core.rescanWorkflows(in: work)

        let off = try #require(await summary(core, work, "weekly"))
        #expect(off.isEnabled == false)
        #expect(off.nextFireAt == nil)

        await core.tickWorkflows(now: nineOClock)
        await core.tickWorkflows(now: nineOClock.addingTimeInterval(60))
        guard case .refused(.disabled, _, _) = await summary(core, work, "weekly")?.lastOutcome else {
            Issue.record("expected a disabled refusal"); return
        }
        #expect(await core.allAgents().isEmpty)
    }

    @Test func runNowStillRunsIt() async throws {
        let (locations, work) = try temporary()
        try write(enabled: "false", as: "weekly", in: work)
        let core = try await core(locations)
        await core.rescanWorkflows(in: work)

        try await core.runWorkflow(DaemonAPI.WorkflowRequest(folder: work, workflowID: "weekly"))
        #expect(await core.allAgents().count == 1)
        #expect(await summary(core, work, "weekly")?.isEnabled == false)
    }

    @Test func turnedOnItStaysOnAcrossARestart() async throws {
        let (locations, work) = try temporary()
        try write(enabled: "false", as: "weekly", in: work)
        do {
            let core = try await core(locations)
            await core.rescanWorkflows(in: work)
            _ = try await core.setWorkflowEnabled(
                DaemonAPI.WorkflowEnableRequest(folder: work, workflowID: "weekly", enabled: true))
            #expect(await summary(core, work, "weekly")?.isEnabled == true)
            #expect(await summary(core, work, "weekly")?.nextFireAt != nil)
        }
        let again = try await core(locations)
        await again.rescanWorkflows(in: work)
        #expect(await summary(again, work, "weekly")?.isEnabled == true,
                "the person's choice wins over where the file starts it")
    }

    @Test func anAgentCannotTurnOnWhatTheFileStartsOff() async throws {
        let (locations, work) = try temporary()
        let core = DaemonCore(store: try AgentStore(locations: locations), locations: locations,
                              discovery: .findsEverything,
                              launcher: FakeLauncher(script: FakeACPAgent.Script(gate: TurnGate())))
        await core.loadFromDisk()
        let agentID = try await core.start(DaemonAPI.StartRequest(runtimeID: "claude", cwd: work, prompt: "Do"))
        let token = UUID().uuidString
        await core.bindAppToken(token, to: agentID)
        _ = try await core.manageWorkflows(DaemonAPI.ManageWorkflowsRequest(
            token: token, action: .write, workflowID: "weekly", content: text(enabled: "false")))
        #expect(await summary(core, work, "weekly")?.isEnabled == false)

        await core.bindAppToken(token, to: agentID)
        await #expect(throws: JSONRPCError.self) {
            _ = try await core.manageWorkflows(DaemonAPI.ManageWorkflowsRequest(
                token: token, action: .enable, workflowID: "weekly"))
        }
        #expect(await summary(core, work, "weekly")?.isEnabled == false)
    }
}
