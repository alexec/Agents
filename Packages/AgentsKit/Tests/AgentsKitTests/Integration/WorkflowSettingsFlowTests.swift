import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// A workflow that says how it runs, driven through the real daemon.
///
/// The runtime is the fake launcher, so an agent really starts and really finishes
/// without a CLI, a credential or a network — which is what lets these assert on what
/// the runtime was actually told rather than on what we meant to tell it.
@Suite("A workflow that says how it runs", .timeLimit(.minutes(1)))
struct WorkflowSettingsFlowTests {
    // MARK: Scaffolding

    private func temporary() throws -> (StoreLocations, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsWorkflowTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (StoreLocations(root: root), root.resolvingSymlinksInPath())
    }

    private func project(_ root: URL, _ name: String = "api") throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return Project.standardize(url)
    }

    @discardableResult
    private func write(_ text: String, as workflowID: String, in project: URL) throws -> URL {
        let folder = WorkflowFile.folder(in: project)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = WorkflowFile.url(for: workflowID, in: project)
        try Data(text.utf8).write(to: url)
        return url
    }

    /// The launcher comes back as well as the core: what the runtime was told is the
    /// only thing worth asserting here, and the fake is the only one who heard it.
    private func core(_ locations: StoreLocations,
                      script: FakeACPAgent.Script = .init()) async throws -> (DaemonCore, FakeLauncher) {
        let store = try AgentStore(locations: locations)
        let launcher = FakeLauncher(script: script)
        let core = DaemonCore(store: store, locations: locations,
                              discovery: .findsEverything, launcher: launcher)
        await core.loadFromDisk()
        return (core, launcher)
    }

    /// A runtime that offers a mode under an id that is not `mode`, and a model under
    /// an id that is not `model`, so anything hard-coding either name fails here.
    private func offering(modes: [String], models: [String] = ["opus"]) -> FakeACPAgent.Script {
        var script = FakeACPAgent.Script()
        script.configOptions = [
            ConfigOption(id: "permission_mode", name: "Mode", category: "mode", type: "select",
                         currentValue: .string(modes.first ?? "default"),
                         options: modes.map { ConfigChoice(value: .string($0), name: $0) }),
            ConfigOption(id: "llm", name: "Model", category: "model", type: "select",
                         options: models.map { ConfigChoice(value: .string($0), name: $0) })
        ]
        return script
    }

    private func file(_ settings: String) -> String {
        """
        ---
        on:
          - schedule:
              at: [":00"]
        agent: new
        \(settings)
        ---

        Say hello and stop.
        """
    }

    private func run(_ core: DaemonCore, _ work: URL,
                     _ id: String = "say-hello") async throws -> WorkflowSummary {
        try await core.runWorkflow(DaemonAPI.WorkflowRequest(folder: work, workflowID: id))
    }

    // MARK: What the runtime is told

    @Test func theModeInTheFileReachesTheRuntime() async throws {
        let (locations, root) = try temporary()
        let work = try project(root)
        try write(file("permission-mode: plan"), as: "say-hello", in: work)

        let (core, launcher) = try await core(locations, script: offering(modes: ["default", "plan"]))
        await core.rescanWorkflows(in: work)
        let summary = try await run(core, work)

        if case .ran = summary.lastOutcome {} else {
            Issue.record("expected a run, got \(String(describing: summary.lastOutcome))")
        }
        // What the runtime was actually told, from its own ledger — never what we
        // recorded against the agent, which would be this app agreeing with itself.
        let sent = await launcher.lastAgent?.setOptions
        #expect(sent?.contains { $0.id == "permission_mode" && $0.value == .string("plan") } == true)
        // Under the id the runtime advertised, and not under "mode".
        #expect(sent?.contains { $0.id == "mode" } != true)
        // One process. Asking what the runtime offered reused the session it answered
        // with, rather than starting a second one to run in.
        #expect(await launcher.launchCount == 1)
    }

    @Test func aWorkflowWithNoSettingsTakesTheOldPath() async throws {
        let (locations, root) = try temporary()
        let work = try project(root)
        try write(file("name: Plain"), as: "say-hello", in: work)

        let (core, launcher) = try await core(locations, script: offering(modes: ["default", "plan"]))
        await core.rescanWorkflows(in: work)
        _ = try await run(core, work)

        #expect(await core.allAgents().count == 1)
        // Nothing was sent, so every default the runtime has stands (S1, SC-006). The
        // draft itself is not observable once the run is over — `start` takes it either
        // way — so what is asserted is its whole consequence: one process, and not a
        // word said to the runtime about how to behave.
        #expect(await launcher.lastAgent?.setOptions.isEmpty == true)
        #expect(await launcher.launchCount == 1)
        #expect(await core.drafts.isEmpty)
    }

    // MARK: What happens when it cannot be had

    @Test func aModeTheRuntimeDoesNotOfferStartsNoAgent() async throws {
        let (locations, root) = try temporary()
        let work = try project(root)
        try write(file("permission-mode: plan"), as: "say-hello", in: work)

        // This runtime has no plan mode.
        let (core, launcher) = try await core(locations, script: offering(modes: ["default", "acceptEdits"]))
        await core.rescanWorkflows(in: work)
        let summary = try await run(core, work)

        // Both halves matter. A test that only checked the refusal was recorded would
        // pass while an agent ran in the wrong mode, which is the entire failure this
        // feature exists to prevent.
        #expect(await core.allAgents().isEmpty)
        guard case .refused(.settingRefused(let setting, let detail), _, _) = summary.lastOutcome else {
            Issue.record("expected a settings refusal, got \(String(describing: summary.lastOutcome))")
            return
        }
        #expect(setting == WorkflowSettings.Setting.permissionMode)
        // It names what would have worked, because the reader's next move is to edit
        // the file.
        #expect(detail.contains("plan"))
        #expect(detail.contains("acceptEdits"))
        // The session made to ask the question was let go of, not left running.
        #expect(await core.drafts.isEmpty)
        #expect(await launcher.launchCount == 1)
    }

    @Test func aWorkflowNamingAnUnknownRuntimeIsRefusedNotRehomed() async throws {
        let (locations, root) = try temporary()
        let work = try project(root)
        try write(file("runtime: nonesuch"), as: "say-hello", in: work)

        let (core, launcher) = try await core(locations)
        await core.rescanWorkflows(in: work)
        let summary = try await run(core, work)

        #expect(await core.allAgents().isEmpty)
        // Nothing was started at all: a workflow that says `runtime: grok` and quietly
        // runs on Claude is the same betrayal as one that loses its permission mode.
        #expect(await launcher.launchCount == 0)
        guard case .refused(.settingRefused(let setting, _), _, _) = summary.lastOutcome else {
            Issue.record("expected a settings refusal, got \(String(describing: summary.lastOutcome))")
            return
        }
        #expect(setting == WorkflowSettings.Setting.runtime)
    }

    @Test func fourRefusalsInARowAreOneRowWithACount() async throws {
        let (locations, root) = try temporary()
        let work = try project(root)
        try write(file("permission-mode: plan"), as: "say-hello", in: work)

        let (core, _) = try await core(locations, script: offering(modes: ["default"]))
        await core.rescanWorkflows(in: work)
        var summary: WorkflowSummary?
        for _ in 1...4 { summary = try await run(core, work) }

        guard case .refused(_, _, let repeats) = summary?.lastOutcome else {
            Issue.record("expected a refusal, got \(String(describing: summary?.lastOutcome))")
            return
        }
        // A weekend of the same problem is one line saying it happened four times, not
        // four lines. The sentence may differ between them — it names what the runtime
        // offered at the time — and the setting is what makes them the same reason.
        #expect(repeats == 4)
    }

    // MARK: Changing one from the page

    @Test func writingASettingChangesTheFileAndNothingElse() async throws {
        let (locations, root) = try temporary()
        let work = try project(root)
        let url = try write("""
            ---
            name: Say hello
            on:
              - schedule:
                  at: [":00"]
            agent: new   # a fresh one every time
            ---

            Say hello and stop.
            """, as: "say-hello", in: work)

        let (core, _) = try await core(locations)
        await core.rescanWorkflows(in: work)
        let before = try String(contentsOf: url, encoding: .utf8)
        _ = try await core.setWorkflowSettings(
            DaemonAPI.WorkflowSettingsRequest(folder: work, workflowID: "say-hello",
                                              settings: WorkflowSettings(permissionMode: "plan")))

        let after = try String(contentsOf: url, encoding: .utf8)
        // One line added, just inside the closing fence, and every other line of
        // somebody's file exactly as they left it — the comment included.
        #expect(after == before.replacingOccurrences(
            of: "agent: new   # a fresh one every time\n---",
            with: "agent: new   # a fresh one every time\npermission-mode: plan\n---"))
    }

    @Test func theWindowHearsAboutItWithoutWaitingForTheWatcher() async throws {
        let (locations, root) = try temporary()
        let work = try project(root)
        try write(file("name: Say hello"), as: "say-hello", in: work)

        let (core, _) = try await core(locations)
        await core.rescanWorkflows(in: work)
        let summary = try await core.setWorkflowSettings(
            DaemonAPI.WorkflowSettingsRequest(folder: work, workflowID: "say-hello",
                                              settings: WorkflowSettings(permissionMode: "plan")))

        // Not after a sleep, and not on the next notification: the answer to the write
        // already carries what the file now says. The watcher is debounced by 250ms,
        // and waiting that long to show somebody what they just asked for reads as the
        // app having ignored them.
        #expect(summary.workflow.settings.permissionMode == "plan")
        #expect(summary.workflow.summary.contains("in plan mode"))
    }

    @Test func aSettingOnAReadOnlyFileIsRefusedAndNotHeld() async throws {
        let (locations, root) = try temporary()
        let work = try project(root)
        let url = try write(file("name: Say hello"), as: "say-hello", in: work)

        let (core, _) = try await core(locations)
        await core.rescanWorkflows(in: work)
        let before = try String(contentsOf: url, encoding: .utf8)

        // An atomic write makes its temporary alongside, so it is the folder that has
        // to refuse it.
        let folder = WorkflowFile.folder(in: work)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }

        await #expect(throws: JSONRPCError.self) {
            try await core.setWorkflowSettings(
                DaemonAPI.WorkflowSettingsRequest(folder: work, workflowID: "say-hello",
                                                  settings: WorkflowSettings(permissionMode: "plan")))
        }
        // Refused, and nothing kept: the file is what it was, and the workflow the
        // daemon holds still says what the file says.
        #expect(try String(contentsOf: url, encoding: .utf8) == before)
        #expect(await core.allWorkflows(in: work).first?.workflow.settings.isEmpty == true)
    }

    @Test func rememberedOptionsStartsNothing() async throws {
        let (locations, root) = try temporary()
        let work = try project(root)

        let (core, launcher) = try await core(locations, script: offering(modes: ["default", "plan"]))
        let offered = await core.rememberedOptions(
            DaemonAPI.RememberedOptionsRequest(runtimeID: "claude", cwd: work))

        // Nothing remembered here yet, and — the point of the method — nothing started
        // to find out. Reading a workflow must not spawn a runtime.
        #expect(offered.isEmpty)
        #expect(await launcher.launchCount == 0)
    }
}
