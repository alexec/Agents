import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// Opt-in, against the real runtimes: `AGENTS_LIVE=1 swift test --filter Live`.
///
/// Everything in `ToolPolicyCatalog` is a claim about somebody else's software: that a
/// key path exists, that a flag is spelled a particular way, that a name is the name the
/// runtime knows. Nothing in this repository can hold those true. What this suite does is
/// re-take the measurements — start each runtime exactly as the app starts it, scoped
/// exactly as the app scopes it, and ask the agent itself what it can call.
///
/// Read as a report rather than as a gate. ACP has no method that lists an agent's tools,
/// so the inventory is the agent's own prose; it is good enough to notice that a removal
/// stopped working and not good enough to trust for an exact id. A failure here is news
/// about a runtime that moved, not a bug in this app — record it in
/// `specs/015-runtime-tool-scoping/research.md` rather than deleting the expectation.
///
/// **What the runs so far say**, taken 2026-09-19 against the versions in research.md:
/// Claude loses all seventeen and keeps `AskUserQuestion`; Grok loses its seven and keeps
/// `workflow` and `monitor` whatever we ask; Copilot loses its five and its whole
/// `software-factory` server, and holds on to `search_code_subagent` under a name the
/// flag will not accept. Cursor has no lever and is not asserted on here at all.
///
/// - **2026-09-20**, re-taken through this suite for the first time: every policy still
///   holds, all five green, and the check script reports nothing unaccounted for on any
///   of the four. Neither piece of residue has become removable — both the expectations
///   that assert residue is *present* passed, which is what keeps those names in
///   `residue` rather than in `removed`.
///
///   The first attempt failed seven expectations, all of them Copilot's, and none of them
///   about Copilot. It answers `Info: Disabled tools: list_agents, read_agent, …` as agent
///   message text, so the inventory contained, verbatim, the five names it had just taken
///   away — the wrinkle R5 recorded as "untidy, not harmful", which is harmful to exactly
///   this. `inventory` now drops chunks beginning `Info:`. Anything else written to read a
///   tool list out of a conversation will need the same.
///
///   Three drifts worth knowing, none of them changing a policy line, all of them in
///   research.md R12: Claude has grown `ToolSearch` and the plan-mode and worktree tools
///   since R1; Grok's `image_edit` survives the overlay that removes `image_gen`; and
///   Copilot's `chrome-devtools` tools were present on one run and absent on the next with
///   the same flag passed both times.
///
// Serialised: four runtimes at once is four models and four sets of output interleaved,
// which is a report nobody can read.
@Suite("Live: what a scoped runtime will admit to having", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["AGENTS_LIVE"] == "1"),
       .timeLimit(.minutes(5)))
struct RuntimeToolScopingLiveTests {
    /// One prompt, asked the same way of every runtime. Deliberately blunt: a model asked
    /// to be thorough about its own tools lists them, and a model asked to be brief
    /// summarises, which is the one thing that would make this unreadable.
    private static let asking = """
        List the exact name of every tool you can call, one per line, with no other text \
        and no commentary. Do not call any tool to answer; just list them.
        """

    private func workspace() throws -> (StoreLocations, URL) {
        let root = URL(filePath: NSTemporaryDirectory()).appending(path: "AgentsScope-\(UUID().uuidString)")
        let work = root.appending(path: "work")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        return (StoreLocations(root: root), work.resolvingSymlinksInPath())
    }

    /// Start a runtime the way the app starts it, scope it the way the app scopes it, and
    /// hand back whatever the agent said about its own tools.
    ///
    /// The three levers all apply here, and that is the point of going through the policy
    /// rather than writing the flags out: a test that built the command line by hand would
    /// pass on a policy the app never sends.
    private func inventory(of runtime: Runtime, policy: ToolPolicy) async throws -> String {
        let (locations, work) = try workspace()
        let discovery = RuntimeDiscovery()
        guard case .available(let path, _) = discovery.locate(runtime) else {
            Issue.record("\(runtime.name) is not installed")
            throw CancellationError()
        }
        let environment = RuntimePolicyFiles(locations: locations)
            .environment(for: policy, onto: LoginShellPath.environment())
        let session = try ACPSession.launch(executable: URL(filePath: path),
                                            arguments: runtime.arguments + policy.launchArguments,
                                            cwd: work,
                                            environment: environment,
                                            capabilities: .app)

        let said = Spoken()
        let events = session.eventStream()
        let watching = Task {
            for await event in events {
                switch event {
                case .entry(.agentMessage(_, let text, _)):
                    // Not everything a runtime says in a session is the agent speaking.
                    // Copilot confirms its own scoping as agent message text rather than
                    // on stderr — `Info: Disabled tools: list_agents, read_agent, …` —
                    // which is the wrinkle Research R5 wrote down, and it means the
                    // inventory would otherwise contain, verbatim, the names that were
                    // just taken away. A test reading that would report the removal
                    // failing at the exact moment it worked.
                    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("Info:") else {
                        break
                    }
                    said.add(text)
                case .permissionRequested(let request):
                    // Nobody is watching this one. A run that stalls on an unanswered
                    // question says nothing about which tools are there.
                    let allow = request.options.first { $0.kind.allows }?.optionID
                    await session.answerPermission(id: request.id, optionID: allow)
                default:
                    break
                }
            }
        }
        defer { watching.cancel() }

        _ = try await session.initialize()
        _ = try await session.newSession(cwd: work, meta: policy.sessionMeta)
        _ = try await session.prompt(Self.asking)
        await session.end()

        let answer = said.text
        print("== \(runtime.id), scoped by \(policy.lever)\n\(answer)\n")
        return answer
    }

    /// Both halves of every case below, said once.
    ///
    /// The second half is the one that matters most and is easiest to forget: an agent
    /// stripped of the tools it needs to read, edit or run anything is not scoped, it is
    /// broken, and a policy that removed everything would pass a test that only checked
    /// for absence.
    private func check(_ answer: String, gone: [String], present: [String],
                       sourceLocation: SourceLocation = #_sourceLocation) {
        for name in gone {
            #expect(!answer.contains(name), "\(name) is still there", sourceLocation: sourceLocation)
        }
        for name in present {
            #expect(answer.contains(name), "\(name) went and should not have",
                    sourceLocation: sourceLocation)
        }
    }

    // MARK: US1 — the schedule lands in the app

    @Test func claudeLosesItsOwnSchedulingAndAgentTools() async throws {
        let answer = try await inventory(of: RuntimeCatalog.claude, policy: ToolPolicyCatalog.claude)
        check(answer,
              gone: ["Workflow", "CronCreate", "ScheduleWakeup", "ListAgents", "ReportFindings"],
              // `AskUserQuestion` first, because it is the one thing this feature could
              // break that would matter more than anything it fixes.
              present: ["AskUserQuestion", "Bash", "Read", "Edit", "Write"])
    }

    /// Grok is the case where the residue is asserted as *present*, which reads like a
    /// test of somebody else's bug and is deliberate: the day Grok lets the allowlist
    /// strip `workflow`, this fails, and the policy gets a line moved out of `residue`
    /// rather than a line quietly left wrong.
    @Test func grokLosesItsSchedulerAndSubagentsAndKeepsItsWorkflowTool() async throws {
        let answer = try await inventory(of: RuntimeCatalog.grok, policy: ToolPolicyCatalog.grok)
        check(answer,
              gone: ["scheduler_create", "scheduler_delete", "scheduler_list",
                     "spawn_subagent", "send_feedback"],
              present: ["ask_user_question", "read_file", "grep", "run_terminal_command", "write",
                        "workflow", "monitor"])
    }

    // MARK: US2, US3, US4 — the rival server goes whole

    /// One flag closes an escalation queue, a suggestion tool and an artefact store at
    /// once, because all three are on the same server.
    @Test func copilotLosesItsRivalServerAndItsSubagents() async throws {
        let answer = try await inventory(of: RuntimeCatalog.copilot, policy: ToolPolicyCatalog.copilot)
        check(answer,
              gone: ["software-factory", "escalation_raise", "prompt_suggest", "output_list",
                     "github-mcp-server",
                     "task", "list_agents", "read_agent", "write_agent", "session_store_sql"],
              present: ["bash", "view", "apply_patch"])
    }

    /// The artefact half, which is the one that could have taken too much: the person's
    /// connectors that merely search the world duplicate nothing of ours, and FR-010 says
    /// leave them. A policy that quietly removed every connector would pass the first two
    /// expectations and fail the third.
    @Test func claudeLosesTheStoresAndKeepsTheConnectorsWeHaveNoOpinionAbout() async throws {
        let answer = try await inventory(of: RuntimeCatalog.claude, policy: ToolPolicyCatalog.claude)
        check(answer,
              gone: ["mcp__claude_ai_Claude_Docs", "mcp__claude_ai_Google_Drive"],
              present: ["mcp__claude_ai_Crustdata"])
    }

    // MARK: FR-014 — a name that no longer exists

    /// Runtimes rename and retire tools, and a policy written once goes stale on its own.
    /// What must not happen is that the stale entry takes the session with it, or stops
    /// the removals that are still good from applying.
    @Test func aNameNoRuntimeKnowsDoesNotStopTheRest() async throws {
        var stale = ToolPolicyCatalog.copilot
        stale.removed.append(RemovedTool(name: "not_a_real_tool_at_all", category: .agents))
        let answer = try await inventory(of: RuntimeCatalog.copilot, policy: stale)

        // The session started at all, which is the whole claim.
        #expect(!answer.isEmpty, "the session did not start, or the agent said nothing")
        check(answer, gone: ["list_agents", "session_store_sql"], present: ["bash"])
    }
}

/// What the agent said, collected across the actor boundary.
final class Spoken: @unchecked Sendable {
    private let lock = NSLock()
    private var chunks: [String] = []

    func add(_ text: String) {
        lock.lock(); defer { lock.unlock() }
        chunks.append(text)
    }

    var text: String {
        lock.lock(); defer { lock.unlock() }
        return chunks.joined()
    }
}
