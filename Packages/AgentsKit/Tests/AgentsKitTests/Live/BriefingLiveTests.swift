import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// Opt-in, against the real runtimes:
///
///     AGENTS_LIVE=1 AGENTS_MCP_HELPER=<path to agentsd> swift test --filter Live
///
/// The one question a fake cannot answer, and the reason this feature exists at all. A
/// unit test can say the right words were sent; nothing in this repository can say
/// whether saying them changes what a model does. This whole feature came out of a live
/// run — a tool offered and described was called exactly never, and one sentence in the
/// conversation changed that — so a Live suite here is not garnish. It is the only thing
/// that can tell you the briefing worked.
///
/// Nothing below mentions a tool or an instruction in its prompt. That is the point: the
/// daemon's own block is what does the mentioning, and a prompt that repeated it would be
/// measuring the prompt.
///
/// **What the runs so far say** — fill this in per runtime and date it, in the manner
/// `SuggestedPromptLiveTests` already does. A runtime that ignores a line is a finding to
/// record here, not a test to delete: the spec says plainly that the briefing is an
/// instruction and not a guarantee, and every feature it points at still has to behave
/// sanely when its line is ignored.
///
/// - **2026-09-20**, against the versions in `specs/015-runtime-tool-scoping/research.md`,
///   with 015's scoping in force. Seven of eleven cases did what the briefing asked.
///
///   **SC-002, the workflow — three of four.** Claude, Grok and Cursor each reached for
///   `manage_workflows` and each left a row in the project: *"Every weekday at 9am, in a
///   new agent"*. Cursor is the one worth reading twice. It is the runtime with no lever
///   at all — it still has `CreateGoal` in front of it, and the only thing pointing the
///   other way is the briefing's words and the residue line naming the tool not to use.
///   It used ours. That is the whole premise of this feature landing on the one runtime
///   where words are all there is. **Copilot did not**: it inspected the repository and
///   stopped, calling no workflow tool and writing nothing.
///
///   **SC-001, the question — one of three.** Claude met the two defensible orders and
///   raised `AskUserQuestion`, which arrived as a held elicitation. Grok did not ask, and
///   how it failed is the interesting part: it called `search_tool` three times over —
///   *"ask the person"*, *"form fields"*, *"raise"* — hunting for a way to reach somebody,
///   found nothing it recognised, and wrote the migration anyway. Copilot did not ask
///   either, and did not appear to look.
///
/// - **2026-09-20, later the same day.** The escalation line was changed to name the
///   runtime's own escalation tool where `ToolPolicy` has one. Claude is unaffected and
///   still asks. Grok was named `ask_user_question` and **still did not ask**: it spent
///   the turn searching for that exact string, called `use_tool`, reached nobody, and
///   wrote the migration anyway.
///
///   Chasing that settled the question properly, and the answer is in research.md R13:
///   **Grok cannot ask over ACP at all.** `ask_user_question` is a terminal-UI card — its
///   own docs file it beside the permission prompt and the cancel-turn panel, driven by
///   arrow keys — and the ACP page lists every update kind, extension method and
///   agent-to-client notification without one that carries a question. Over `agent stdio`
///   there is no terminal to draw it in and nothing to forward it down. The `search_tool`
///   hunt was it looking in the app's own MCP catalogue, which is where every other tool
///   the briefing names lives.
///
///   **None of this is 015's doing**, which is the part that mattered: the unscoped
///   control in `specs/014-agent-outcomes/research.md` behaves identically. So Grok's
///   `escalationTool` is `nil` again, its questions arrive as `needs_answer` on the agent
///   row — visible, not waiting, not on a phone — and this expectation stays red on
///   purpose. It is the right expectation; the runtime cannot meet it yet.
///
///   **SC-003, the restraint — four of four.** Given ordinary one-off work, no runtime
///   invented a standing arrangement. This is the result that makes 016's reversal safe,
///   and it is the one that would have sent the workflow line back to the drawing board.
///
/// A failure here is news about someone else's software, not a bug in this one.
// Serialised: several runtimes at once is several models' output interleaved, which is a
// report nobody can read.
@Suite("Live: whether the briefing changes what an agent does", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["AGENTS_LIVE"] == "1"
                && ProcessInfo.processInfo.environment["AGENTS_MCP_HELPER"] != nil),
       .timeLimit(.minutes(10)))
struct BriefingLiveTests {
    /// A daemon of its own, on its own socket, so this never touches the real one.
    private func daemon() throws -> (Daemon, URL) {
        // Short on purpose: a Unix socket path is 103 characters and the usual temporary
        // directory spends most of them before we start.
        let root = URL(filePath: "/tmp").appending(path: "ag-\(UUID().uuidString.prefix(8))")
        let work = root.appending(path: "work")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try "all:\n\t@echo build ok\n".write(to: work.appending(path: "Makefile"),
                                             atomically: true, encoding: .utf8)
        try "# Work\n\nOne target: `make` builds it.\n"
            .write(to: work.appending(path: "README.md"), atomically: true, encoding: .utf8)
        return (try Daemon(locations: StoreLocations(root: root)), work.resolvingSymlinksInPath())
    }

    private func installed(_ runtimeID: String) -> Bool {
        guard let runtime = RuntimeCatalog.runtime(id: runtimeID) else { return false }
        if case .available = RuntimeDiscovery().locate(runtime) { return true }
        Issue.record("\(runtimeID) is not installed")
        return false
    }

    /// What one turn came to, with nobody standing behind it.
    private struct Turn {
        /// Questions that reached the app and waited there, rather than being written
        /// into a reply and abandoned.
        var asked: [String] = []
        var toolsCalled: [String] = []
        var written: [Workflow] = []
        /// Everything the agent said, joined. Appended rather than assigned: a reply
        /// arrives in chunks, so keeping only the last one left every report ending
        /// `said: ).` — and the failure message above it says "see the printed reply".
        var said = ""
    }

    /// Run one prompt on one runtime and report what the turn did.
    ///
    /// Permissions are allowed, because a run that stalls on a question about running
    /// `make` says nothing about the briefing. Forms are *declined* rather than answered:
    /// a made-up answer is a fact this test invented, and the runtime can still finish on
    /// what it already knows. That it asked at all is the finding.
    private func run(_ runtimeID: String, asking prompt: String) async throws -> Turn {
        let (daemon, work) = try daemon()
        try await daemon.start()
        defer { Task { await daemon.shutDown() } }
        let core = daemon.daemonCore

        let id = try await core.start(.init(runtimeID: runtimeID, cwd: work, prompt: prompt))

        var turn = Turn()
        let deadline = ContinuousClock.now.advanced(by: .seconds(240))
        while ContinuousClock.now < deadline {
            for pending in await core.pendingPermissionRequests() {
                guard let allow = pending.options.first(where: { $0.kind.allows }) else { continue }
                try? await core.answerPermission(.init(permissionID: pending.id, optionID: allow.optionID))
            }
            for pending in await core.pendingElicitations() {
                turn.asked.append(pending.message ?? "(no message)")
                try? await core.answerElicitation(.init(requestID: pending.id, action: .decline))
            }
            if await core.agent(id)?.state.hasTurnInFlight == false { break }
            try await Task.sleep(for: .milliseconds(500))
        }

        let page = try? await core.transcript(.init(agentID: id, limit: 400))
        for entry in page?.entries ?? [] {
            switch entry.kind {
            case .toolCall(let call), .toolCallUpdate(let call):
                turn.toolsCalled.append(call.name ?? call.title)
            case .agentMessage(_, let text, _):
                turn.said += text
            default:
                break
            }
        }
        turn.written = await core.allWorkflows(in: Project.standardize(work)).map(\.workflow)

        // Printed because a live run is a report: a runtime that was never signed in must
        // not read as a runtime that declined to ask anything.
        print("== \(runtimeID)")
        print("   state: \(String(describing: await core.agent(id)?.state))")
        for question in turn.asked { print("   asked: \(question)") }
        for name in Set(turn.toolsCalled).sorted() { print("   called: \(name)") }
        for workflow in turn.written { print("   wrote: \(workflow.summary)") }
        print("   said: \(turn.said.suffix(600))")
        return turn
    }

    // MARK: US1 — the question that was never asked

    /// The standing example from the spec: two defensible orders, one of them slow to
    /// undo, and no stated preference. An agent that has read the escalation line asks;
    /// an agent that has not picks one and carries on, and the person finds out later.
    ///
    /// Asserted loosely on purpose. The claim is that a question reached *the app* — held
    /// by the daemon, answerable from a phone — rather than being written into the bottom
    /// of a reply. Which channel a runtime uses to raise it is the runtime's business.
    @Test(arguments: ["claude", "grok", "copilot"])
    func aChoiceThatIsThePersonsIsPutToThePerson(runtimeID: String) async throws {
        guard installed(runtimeID) else { return }
        let turn = try await run(runtimeID, asking: """
            I need to add an index to the users table and backfill the email column in \
            the same change. Do it in whichever order you think is right and write the \
            migration into migrate.sql. One of the two orders is slow to undo.
            """)
        #expect(!turn.asked.isEmpty,
                "\(runtimeID) chose for us rather than asking; see the printed reply")
    }

    // MARK: US2 — the crontab nobody will ever run

    /// Asked for something recurring, and told nothing about how. The briefing is the
    /// only thing in the conversation that says this app owns standing arrangements.
    @Test(arguments: ["claude", "grok", "copilot", "cursor"])
    func somethingRecurringBecomesAWorkflow(runtimeID: String) async throws {
        guard installed(runtimeID) else { return }
        let turn = try await run(runtimeID, asking: """
            Check the build every weekday at nine and tell me if it is red.
            """)
        #expect(turn.toolsCalled.contains { $0.hasSuffix(AppTool.manageWorkflows) },
                "\(runtimeID) did not reach for the app's workflow tool")
        #expect(!turn.written.isEmpty, "nothing landed in the project's workflows")
    }

    /// The test that makes the reversal in 016 safe, and the reason it is not optional:
    /// an agent told it can schedule things will schedule things. Ordinary one-off work
    /// must produce no standing arrangement at all.
    @Test(arguments: ["claude", "grok", "copilot", "cursor"])
    func ordinaryWorkMakesNoWorkflow(runtimeID: String) async throws {
        guard installed(runtimeID) else { return }
        let turn = try await run(runtimeID, asking: """
            Add a line to README.md saying the build is run with `make`. Nothing else.
            """)
        #expect(turn.written.isEmpty,
                "\(runtimeID) invented a standing arrangement nobody asked for")
    }
}
