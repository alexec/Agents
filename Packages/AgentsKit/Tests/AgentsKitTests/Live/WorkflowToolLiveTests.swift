import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// Opt-in, against the real runtimes:
///
///     AGENTS_LIVE=1 AGENTS_MCP_HELPER=<path to agentsd> swift test --filter Live
///
/// The question a fake cannot answer. `manage_workflows` is offered to every agent and
/// nothing in the prompt mentions it — deliberately, see `AppService.workflowTool` —
/// so whether a person asking for a workflow gets one comes down to a tool
/// description, a sentence, and somebody else's model. This sends each runtime the
/// exact sentence the app offers a person with no workflows yet
/// (`WorkflowExample.prompt`) and reads what landed in `.agents/workflows`.
///
/// Two things have to hold, and they fail differently:
///
/// - the runtime found the tool and called it, rather than writing a file itself or
///   describing what it would have written;
/// - what it wrote schedules for the time that was asked for.
///
/// What the runs so far say:
///
/// - **Claude, Grok and Cursor** all write the same file, down to the front matter,
///   and the two that pick a name pick nearly the same one.
/// - **The word "workflow" is not ours.** Asked, in plain words, to "set up a workflow
///   that runs every weekday at 9am", Claude scheduled it with its own cron and
///   Copilot wrote a GitHub Actions file. Naming the tool in the sentence is what
///   settles which kind of workflow is meant, and it is why `WorkflowExample.prompt`
///   reads the way it does.
/// - **Copilot never sees the tool at all.** See `whatCopilotDoesInstead`.
///
/// A failure here is news about someone else's software, or about the wording of the
/// example, not a bug in the scheduler — `Unit/WorkflowScheduleTests` holds that.
// Serialised: four runtimes at once is four models' output interleaved, which is a
// report nobody can read.
@Suite("Live: whether a runtime sets up a workflow when asked", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["AGENTS_LIVE"] == "1"
                && ProcessInfo.processInfo.environment["AGENTS_MCP_HELPER"] != nil),
       .timeLimit(.minutes(10)))
struct WorkflowToolLiveTests {
    /// A daemon of its own, on its own socket, so this never touches the real one.
    private func daemon() throws -> (Daemon, URL) {
        // Short on purpose: a Unix socket path is 103 characters and the usual
        // temporary directory spends most of them before we start.
        let root = URL(filePath: "/tmp").appending(path: "ag-\(UUID().uuidString.prefix(8))")
        let work = root.appending(path: "work")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        // Something for the workflow's prompt to be about, and something that answers
        // it: a build that can actually be run and is actually green. A folder whose
        // build could not work is a folder a good runtime stops to ask about, and the
        // question under test is not that one.
        try "all:\n\t@echo build ok\n".write(to: work.appending(path: "Makefile"),
                                              atomically: true, encoding: .utf8)
        try "# Work\n\nOne target: `make` builds it.\n"
            .write(to: work.appending(path: "README.md"), atomically: true, encoding: .utf8)
        return (try Daemon(locations: StoreLocations(root: root)), work.resolvingSymlinksInPath())
    }

    private func installed(_ runtime: Runtime) -> Bool {
        if case .available = RuntimeDiscovery().locate(runtime) { return true }
        Issue.record("\(runtime.name) is not installed")
        return false
    }

    /// Ask one runtime for the workflow, standing in for the person throughout, and
    /// hand back whatever ended up in the project's workflow folder.
    private func askForAWorkflow(_ runtime: Runtime) async throws
        -> (written: [Workflow], calledTheTool: Bool) {
        let (daemon, work) = try daemon()
        try await daemon.start()
        defer { Task { await daemon.shutDown() } }
        let core = daemon.daemonCore

        let id = try await core.start(.init(runtimeID: runtime.id, cwd: work,
                                            prompt: WorkflowExample.prompt))

        var forms: [String] = []
        let deadline = ContinuousClock.now.advanced(by: .seconds(240))
        while ContinuousClock.now < deadline {
            // Copilot asks before it runs anything and there is nobody here to ask. A
            // run that stalls on an unanswered question says nothing about the tool.
            for pending in await core.pendingPermissionRequests() {
                guard let allow = pending.options.first(where: { $0.kind.allows }) else { continue }
                try? await core.answerPermission(.init(permissionID: pending.id, optionID: allow.optionID))
            }
            // A form is a question to a person, and there is no person. Declined
            // rather than answered: a made-up answer is a fact this test invented, and
            // the runtime can still finish on what it already knows. That it asked at
            // all is the finding, and the report below says so.
            for pending in await core.pendingElicitations() {
                forms.append(pending.message ?? "(no message)")
                try? await core.answerElicitation(.init(requestID: pending.id, action: .decline))
            }
            if await core.agent(id)?.state.hasTurnInFlight == false { break }
            try await Task.sleep(for: .milliseconds(500))
        }

        // Printed because a live run is a report: a runtime that was never signed in
        // must not read as a runtime that declined to write anything, and a runtime
        // that never called the tool has to be readable as *what it did instead*.
        print("== \(runtime.name)")
        print("   state: \(String(describing: await core.agent(id)?.state))")
        for pending in await core.pendingPermissionRequests() {
            print("   still asking permission: \(pending.toolCall.title)")
        }
        for message in forms {
            print("   asked a form, which was declined: \(message)")
        }
        await report(core, id)
        // Whether our tool is what wrote the file, read off the transcript. Every one
        // of these runtimes has file tools of its own, and one that wrote the folder
        // directly would look identical on disk.
        let calledTheTool = await toolNames(core, id).contains { $0.hasSuffix(AppTool.manageWorkflows) }
        let written = await core.allWorkflows(in: Project.standardize(work))
        for summary in written {
            print("   wrote: \(summary.workflowID) — \(summary.workflow.summary)")
            print((try? String(contentsOf: WorkflowFile.url(for: summary.workflowID, in: work),
                               encoding: .utf8)) ?? "   (unreadable)")
        }
        return (written.map(\.workflow), calledTheTool)
    }

    /// Every tool the turn called, in order.
    private func toolNames(_ core: DaemonCore, _ id: UUID) async -> [String] {
        guard let page = try? await core.transcript(.init(agentID: id, limit: 200)) else { return [] }
        return page.entries.compactMap { entry in
            switch entry.kind {
            case .toolCall(let call), .toolCallUpdate(let call): return call.name ?? call.title
            default: return nil
            }
        }
    }

    /// What the agent did with the turn, in one line each.
    ///
    /// Only the two kinds that answer the question this suite asks: which tools it
    /// reached for, and what it said at the end. A runtime that wrote the file with
    /// its own editor, or one that came back asking which build command to use, both
    /// look like "nothing written" without this.
    private func report(_ core: DaemonCore, _ id: UUID) async {
        guard let page = try? await core.transcript(.init(agentID: id, limit: 200)) else { return }
        for entry in page.entries {
            switch entry.kind {
            case .toolCall(let call), .toolCallUpdate(let call):
                print("   tool: \(call.name ?? call.title) [\(call.status ?? "")]")
            case .agentMessage(_, let text, _) where !text.isEmpty:
                print("   said: \(text.prefix(400))")
            default:
                continue
            }
        }
    }

    /// The claim: the sentence the app offers produces a workflow that runs when the
    /// sentence says it does. One test, three runtimes, no `if` on which one.
    ///
    /// Copilot is not in here, and `whatCopilotDoesInstead` below says why.
    @Test(arguments: [RuntimeCatalog.claude, RuntimeCatalog.grok, RuntimeCatalog.cursor])
    func aRuntimeAskedForAWorkflowSchedulesIt(runtime: Runtime) async throws {
        guard installed(runtime) else { return }

        let (written, calledTheTool) = try await askForAWorkflow(runtime)

        // Through the tool, not around it. A runtime that wrote the folder with its own
        // editor leaves the same file and proves nothing about the tool description,
        // which is the thing this suite is actually measuring.
        #expect(calledTheTool,
                "\(runtime.name) produced a workflow without going through the tool")
        #expect(written.count == 1, "\(runtime.name) wrote \(written.count) workflows for one request")
        guard let workflow = written.first else { return }
        #expect(workflow.problem == nil, "\(runtime.name): \(workflow.summary)")
        #expect(workflow.mode == .new)
        #expect(!workflow.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        // Every weekday at 9am, and nothing else. A `between:` an hour wide, or a
        // `days:` left at the default, is a workflow that fires when nobody asked it
        // to, which is the failure this whole test is for.
        #expect(workflow.schedules == [WorkflowExample.schedule],
                "\(runtime.name) scheduled \(workflow.summary)")
    }

    /// Copilot, which is the finding rather than the claim.
    ///
    /// Asked this outright it answers, in its own words, that "the workflow-management
    /// capability isn't available in this session" — and it is right. The helper the
    /// tool lives behind is never started: ask Copilot to list its tools and it names
    /// the MCP servers from its own configuration and none of ours, while the other
    /// three start the helper within seconds. Copilot takes the `mcpServers` on
    /// `session/new` and does nothing with them, which is also the real reason it
    /// never offered a suggestion — see `SuggestedPromptLiveTests`, which reads that
    /// as a preference for its own follow-up feature.
    ///
    /// So this asserts nothing except that we did not quietly get a workflow some
    /// other way. A run where Copilot calls the tool is news, and the printed report
    /// is how it would arrive.
    @Test func whatCopilotDoesInstead() async throws {
        let runtime = RuntimeCatalog.copilot
        guard installed(runtime) else { return }

        let (written, calledTheTool) = try await askForAWorkflow(runtime)

        #expect(calledTheTool == !written.isEmpty,
                "Copilot produced a workflow without going through the tool")
    }
}
