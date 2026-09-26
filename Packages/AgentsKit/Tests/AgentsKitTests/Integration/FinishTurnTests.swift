import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// One call that ends a turn: how it went, and what to ask next (023).
///
/// The daemon's half. What these are for is the shape of the promise: a call lands
/// both halves or neither, a later call is the whole account, and the two older
/// names — still accepted, because a conversation briefed with them is still calling
/// them — leave the agent exactly where the one call would.
@Suite("Ending a turn in one call", .timeLimit(.minutes(1)))
struct FinishTurnTests {
    private func temporary() throws -> (StoreLocations, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsFinishTests-\(UUID().uuidString)", isDirectory: true)
        let work = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        return (StoreLocations(root: root), work)
    }

    private func core(_ launcher: FakeLauncher, locations: StoreLocations) throws -> DaemonCore {
        DaemonCore(store: try AgentStore(locations: locations),
                   locations: locations,
                   discovery: .findsEverything,
                   launcher: launcher)
    }

    /// A turn long enough to call a tool in the middle of, which is when a real one is
    /// called: the daemon lets the runtime go the moment a turn ends, and with it the
    /// MCP helper that runtime started.
    private func midTurn() -> FakeLauncher {
        var script = FakeACPAgent.Script()
        script.turnDelay = .milliseconds(400)
        return FakeLauncher(script: script)
    }

    private func mintedToken(_ launcher: FakeLauncher) async -> String {
        await eventuallySome("the runtime was handed its token") {
            let attached = await launcher.lastAgent?.newSessionParams?["mcpServers"]?.arrayValue ?? []
            let minted = attached.first?["args"]?.arrayValue?.last?.stringValue ?? ""
            return minted.isEmpty ? nil : minted
        } ?? ""
    }

    /// Wait until the turn is over, nothing is queued, and the runtime has been let go.
    private func settle(_ core: DaemonCore, _ id: UUID) async throws {
        let deadline = ContinuousClock.now.advanced(by: max(.seconds(5), Eventually.timeout))
        while ContinuousClock.now < deadline {
            if let agent = await core.agent(id),
               !agent.state.hasTurnInFlight, agent.queuedPrompts.isEmpty,
               await core.live[id] == nil {
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func chips(_ labels: [String]) -> [SuggestedPrompt] {
        labels.map { SuggestedPrompt(label: $0, prompt: "Do \($0)") }
    }

    @discardableResult
    private func finish(_ core: DaemonCore, _ launcher: FakeLauncher,
                        _ outcome: String, _ message: String,
                        _ labels: String...) async throws -> String {
        try await core.finishTurn(.init(token: await mintedToken(launcher),
                                        outcome: outcome, message: message,
                                        prompts: chips(labels)))
    }

    private func reported(_ core: DaemonCore, _ id: UUID) async throws -> [WorkReport] {
        try await core.transcript(.init(agentID: id)).entries.compactMap { entry in
            if case .workReported(let report) = entry.kind { return report }
            return nil
        }
    }

    // MARK: The turn ends in one breath

    /// US1, whole: one call, and the agent reads as a report and a suggestion — the
    /// first of what was sent, since 031 keeps one.
    @Test func oneCallLandsTheReportAndTheChips() async throws {
        let (locations, work) = try temporary()
        let launcher = midTurn()
        let core = try core(launcher, locations: locations)
        let id = try await core.start(.init(runtimeID: "copilot", cwd: work, prompt: "go"))

        try await finish(core, launcher, "done", "Renamed the call sites; tests pass.", "A", "B")
        try await settle(core, id)

        let agent = try #require(await core.agent(id))
        #expect(agent.report?.outcome == .done)
        #expect(agent.report?.message == "Renamed the call sites; tests pass.")
        #expect(agent.suggestedPrompts.map(\.label) == ["A"])
        #expect(agent.group(wantsEyes: false) == .finished)
        // One record of it, at the foot, as a report alone leaves.
        #expect(try await reported(core, id).map(\.outcome) == [.done])
    }

    @Test func oneCallWithNoPromptsLeavesNoChips() async throws {
        let (locations, work) = try temporary()
        let launcher = midTurn()
        let core = try core(launcher, locations: locations)
        let id = try await core.start(.init(runtimeID: "copilot", cwd: work, prompt: "go"))

        try await finish(core, launcher, "needs_answer", "Drop the old index first?")
        try await settle(core, id)

        let agent = try #require(await core.agent(id))
        #expect(agent.report?.outcome == .needsAnswer)
        #expect(agent.suggestedPrompts.isEmpty)
        #expect(agent.group(wantsEyes: false) == .needsAttention)
    }

    /// The outcome's sentence first, so an agent that reads one line reads the half
    /// that matters; the chips' sentence after it, only when there were chips.
    @Test func theReplyNamesBothHalves() async throws {
        let (locations, work) = try temporary()
        let launcher = midTurn()
        let core = try core(launcher, locations: locations)
        _ = try await core.start(.init(runtimeID: "copilot", cwd: work, prompt: "go"))

        let both = try await finish(core, launcher, "done", "All done.", "A", "B")
        #expect(both.hasPrefix("Noted."))
        #expect(both.contains(DaemonCore.shownNote))

        let alone = try await finish(core, launcher, "done", "All done.")
        #expect(alone.hasPrefix("Noted."))
        #expect(!alone.contains(DaemonCore.shownNote))
    }

    /// Both are an account of the turn they came from, and the next prompt is the
    /// answer to it.
    @Test func theNextPromptClearsBoth() async throws {
        let (locations, work) = try temporary()
        let launcher = midTurn()
        let core = try core(launcher, locations: locations)
        let id = try await core.start(.init(runtimeID: "copilot", cwd: work, prompt: "go"))

        try await finish(core, launcher, "partly_done", "Five of six.", "Do the sixth")
        try await settle(core, id)
        #expect(await core.agent(id)?.report != nil)
        #expect(await core.agent(id)?.suggestedPrompts.isEmpty == false)

        try await core.prompt(.init(agentID: id, text: "do the sixth"))
        await eventually("the account was cleared") {
            await core.agent(id)?.report == nil
        }
        #expect(await core.agent(id)?.report == nil)
        #expect(await core.agent(id)?.suggestedPrompts.isEmpty == true)
    }

    // MARK: Or neither

    /// The refusal that is the reason the merge lives in the daemon: a form still
    /// waiting refuses the whole call, and no chips are shown over the question.
    @Test func aCallWhileAQuestionIsOutstandingLandsNothing() async throws {
        let (locations, work) = try temporary()
        var script = FakeACPAgent.Script()
        script.turnDelay = .milliseconds(600)
        script.permission = ["toolCall": ["title": "Delete everything"],
                             "options": [["optionId": "allow", "name": "Allow",
                                          "kind": "allow_once"],
                                         ["optionId": "no", "name": "Reject",
                                          "kind": "reject_once"]]]
        let launcher = FakeLauncher(script: script)
        let core = try core(launcher, locations: locations)
        let id = try await core.start(.init(runtimeID: "copilot", cwd: work, prompt: "go"))

        await eventually("the agent is blocked on the question") {
            await core.agent(id)?.state == .waitingOnUser
        }

        let error = await #expect(throws: JSONRPCError.self) {
            _ = try await finish(core, launcher, "done", "all done", "A", "B")
        }
        #expect(error?.code == JSONRPCError.invalidParams)
        #expect(error?.message.contains("question waiting") == true)
        #expect(await core.agent(id)?.report == nil)
        #expect(await core.agent(id)?.suggestedPrompts.isEmpty == true)
    }

    @Test func aTokenThatNoLongerSpeaksForAnAgentIsRefused() async throws {
        let (locations, work) = try temporary()
        let launcher = FakeLauncher()
        let core = try core(launcher, locations: locations)
        _ = try await core.start(.init(runtimeID: "copilot", cwd: work, prompt: "go"))

        let error = await #expect(throws: JSONRPCError.self) {
            _ = try await core.finishTurn(.init(token: "not-a-token", outcome: "done",
                                                message: "all done", prompts: chips(["A"])))
        }
        #expect(error?.code == DaemonAPI.Failure.noSuchAgent)
        #expect(error?.message.contains("not open any more") == true)
    }

    /// The last call is the whole account. A second call with no prompts after a
    /// first with some has changed its mind about the ending, and the chips belonged
    /// to the ending.
    @Test func aSecondCallIsTheWholeAccount() async throws {
        let (locations, work) = try temporary()
        let launcher = midTurn()
        let core = try core(launcher, locations: locations)
        let id = try await core.start(.init(runtimeID: "copilot", cwd: work, prompt: "go"))

        try await finish(core, launcher, "partly_done", "Five of six.", "A", "B")
        try await finish(core, launcher, "done", "Got the sixth after all.")

        let agent = try #require(await core.agent(id))
        #expect(agent.report?.outcome == .done)
        #expect(agent.report?.message == "Got the sixth after all.")
        #expect(agent.suggestedPrompts.isEmpty)
    }

    /// Copilot asks before every tool call, this one included, and a sheet asking
    /// whether the app may end the app's own turn is a question with nothing in it.
    @Test func thePermissionForTheFinishCallIsAnsweredForYou() async throws {
        let (locations, work) = try temporary()
        var script = FakeACPAgent.Script()
        script.permission = [
            "toolCall": ["toolCallId": "call-1", "title": "finish_turn",
                         "name": "mcp__agents__finish_turn"],
            "options": .array([
                ["optionId": "allow", "name": "Allow", "kind": "allow_once"],
                ["optionId": "reject", "name": "Reject", "kind": "reject_once"],
            ]),
        ]
        let launcher = FakeLauncher(script: script)
        let core = try core(launcher, locations: locations)

        let id = try await core.start(.init(runtimeID: "copilot", cwd: work, prompt: "go"))
        await eventually("our own tool's question was answered for us") {
            await launcher.lastAgent?.permissionOutcome != nil
        }
        await eventually("the agent was not left waiting") {
            await core.agent(id)?.state != .waitingOnUser
        }

        #expect(await core.pendingPermissionRequests().isEmpty)
        #expect(await core.agent(id)?.state != .waitingOnUser)
        let outcome = await launcher.lastAgent?.permissionOutcome
        #expect(outcome?["outcome"]?["optionId"]?.stringValue == "allow")
    }

    // MARK: A conversation that was told the old names keeps working

    private func suggest(_ core: DaemonCore, _ launcher: FakeLauncher,
                         _ labels: String...) async throws {
        _ = try await core.suggestPrompts(.init(token: await mintedToken(launcher),
                                                prompts: chips(labels)))
    }

    private func report(_ core: DaemonCore, _ launcher: FakeLauncher,
                        _ outcome: String, _ message: String) async throws {
        _ = try await core.reportOutcome(.init(token: await mintedToken(launcher),
                                               outcome: outcome, message: message))
    }

    /// What an agent looks like after the ending, by whichever door it came.
    private struct Account: Equatable {
        var outcome: WorkOutcome?
        var message: String?
        var labels: [String]
        init(_ agent: Agent) {
            outcome = agent.report?.outcome
            message = agent.report?.message
            labels = agent.suggestedPrompts.map(\.label)
        }
    }

    /// US2, whole: the two old names, in either order, leave the agent exactly where
    /// the one call would (FR-012, SC-006). Three agents, same values.
    @Test func theOldNamesInEitherOrderLeaveTheSameStateAsOneCall() async throws {
        let (locations, work) = try temporary()
        let launcher = midTurn()
        let core = try core(launcher, locations: locations)

        let one = try await core.start(.init(runtimeID: "copilot", cwd: work, prompt: "go"))
        try await finish(core, launcher, "partly_done", "Five of six.", "A", "B")
        try await settle(core, one)

        let suggestThenReport = try await core.start(.init(runtimeID: "copilot", cwd: work, prompt: "go"))
        try await suggest(core, launcher, "A", "B")
        try await report(core, launcher, "partly_done", "Five of six.")
        try await settle(core, suggestThenReport)

        let reportThenSuggest = try await core.start(.init(runtimeID: "copilot", cwd: work, prompt: "go"))
        try await report(core, launcher, "partly_done", "Five of six.")
        try await suggest(core, launcher, "A", "B")
        try await settle(core, reportThenSuggest)

        let expected = Account(try #require(await core.agent(one)))
        #expect(expected.outcome == .partlyDone)
        #expect(expected.labels == ["A"])
        #expect(Account(try #require(await core.agent(suggestThenReport))) == expected)
        #expect(Account(try #require(await core.agent(reportThenSuggest))) == expected)
    }

    /// An old name after the one call replaces only its half.
    @Test func theOldSuggestionNameAloneTouchesOnlyTheChips() async throws {
        let (locations, work) = try temporary()
        let launcher = midTurn()
        let core = try core(launcher, locations: locations)
        let id = try await core.start(.init(runtimeID: "copilot", cwd: work, prompt: "go"))

        try await finish(core, launcher, "done", "All done.", "A", "B")
        try await suggest(core, launcher, "C")

        let agent = try #require(await core.agent(id))
        #expect(agent.suggestedPrompts.map(\.label) == ["C"])
        #expect(agent.report?.outcome == .done)
        #expect(agent.report?.message == "All done.")
    }

    @Test func theOldOutcomeNameAloneTouchesOnlyTheReport() async throws {
        let (locations, work) = try temporary()
        let launcher = midTurn()
        let core = try core(launcher, locations: locations)
        let id = try await core.start(.init(runtimeID: "copilot", cwd: work, prompt: "go"))

        try await finish(core, launcher, "done", "All done.", "A", "B")
        try await report(core, launcher, "stuck", "No signing certificate.")

        let agent = try #require(await core.agent(id))
        #expect(agent.report?.outcome == .stuck)
        #expect(agent.report?.message == "No signing certificate.")
        #expect(agent.suggestedPrompts.map(\.label) == ["A"])
    }

    // MARK: The title

    /// A runtime that names the session itself at the end of the turn — after any tool
    /// the agent called during it — which is exactly when Claude's adapter does.
    private func namingAtTurnEnd(_ title: String) -> FakeLauncher {
        var script = FakeACPAgent.Script()
        script.turnDelay = .milliseconds(400)
        script.title = title
        return FakeLauncher(script: script)
    }

    @Test("The agent's title lands with its report")
    func theTitleLandsWithTheReport() async throws {
        let (locations, work) = try temporary()
        let launcher = midTurn()
        let core = try core(launcher, locations: locations)
        let id = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "fix the login redirect"))

        _ = try await core.finishTurn(.init(token: await mintedToken(launcher),
                                            outcome: "done", message: "The redirect works now.",
                                            prompts: [], title: "Login redirect fixed"))

        let agent = try #require(await core.agent(id))
        #expect(agent.title == "Login redirect fixed")
        #expect(agent.titledByAgent)
        #expect(agent.report?.message == "The redirect works now.")
        try await settle(core, id)
    }

    /// The case the flag exists for. The adapter's title arrives after the agent's
    /// call, and must not replace the name the agent just gave.
    @Test("A runtime title at the end of the turn does not replace the agent's")
    func theRuntimeDoesNotOverwriteTheAgentsTitle() async throws {
        let (locations, work) = try temporary()
        let launcher = namingAtTurnEnd("Fix login redirect issue")
        let core = try core(launcher, locations: locations)
        let id = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "fix the login redirect"))

        _ = try await core.finishTurn(.init(token: await mintedToken(launcher),
                                            outcome: "done", message: "Fixed.",
                                            prompts: [], title: "Login redirect fixed"))
        try await settle(core, id)
        // The turn ending does not mean the runtime's title has been *handled*: it
        // comes on the event stream, which is read on its own task. This proves a
        // thing did not happen, so it is a wait rather than a poll — and the test
        // below proves that, in this very setup, the title does arrive.
        try await Task.sleep(for: .milliseconds(500))

        #expect(await core.agent(id)?.title == "Login redirect fixed")
    }

    /// And the guard is only a guard. Until the agent names the conversation, the
    /// runtime's title is still better than the first line of the prompt.
    @Test("Until the agent names it, a runtime title still fills in")
    func aRuntimeTitleStillFillsIn() async throws {
        let (locations, work) = try temporary()
        let launcher = namingAtTurnEnd("Fix login redirect issue")
        let core = try core(launcher, locations: locations)
        let id = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "fix the login redirect"))
        // Waited for, not assumed after the turn: the title is on the event stream,
        // and the turn ending can be handled before it is. The first draft asserted
        // straight after `settle` and failed under the full suite.
        await eventually("the runtime's title arrived") {
            await core.agent(id)?.title == "Fix login redirect issue"
        }
        #expect(await core.agent(id)?.titledByAgent == false)
        try await settle(core, id)
    }

    /// No title — the agent's goal has not changed, or a helper started from an older
    /// binary sent none. The call still lands, and the name is left as it was rather
    /// than blanked or refused.
    @Test("A call with no title leaves the name as it was")
    func noTitleLeavesTheNameAlone() async throws {
        let (locations, work) = try temporary()
        let launcher = midTurn()
        let core = try core(launcher, locations: locations)
        let id = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "fix the login redirect"))
        let before = await core.agent(id)?.title

        try await finish(core, launcher, "done", "Fixed.")

        let agent = try #require(await core.agent(id))
        #expect(agent.title == before)
        #expect(!agent.titledByAgent)
        #expect(agent.report?.message == "Fixed.")
        try await settle(core, id)
    }

    /// The title names the goal, so it is sent once and then left out while the goal
    /// holds. A later call without one keeps the agent's name — and keeps it the
    /// agent's, so the runtime's title at the end of the turn still does not replace it.
    @Test("A goal title outlasts the calls that leave it out")
    func theGoalTitleOutlastsLaterCalls() async throws {
        let (locations, work) = try temporary()
        let launcher = namingAtTurnEnd("Fix login redirect issue")
        let core = try core(launcher, locations: locations)
        let id = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "fix the login redirect"))
        let token = await mintedToken(launcher)

        _ = try await core.finishTurn(.init(token: token, outcome: "partly_done",
                                            message: "Found the redirect.",
                                            prompts: [], title: "Login redirect"))
        _ = try await core.finishTurn(.init(token: token, outcome: "done", message: "Fixed.",
                                            prompts: []))
        try await settle(core, id)
        // As above: the runtime's title comes on its own task, so this waits for a
        // thing not to happen.
        try await Task.sleep(for: .milliseconds(500))

        let agent = try #require(await core.agent(id))
        #expect(agent.title == "Login redirect")
        #expect(agent.titledByAgent)
        #expect(agent.report?.message == "Fixed.")
    }

    /// The daemon cleans the title as well as the tool, because the daemon is what
    /// writes the record — and a title that cleans to nothing is left out, not drawn.
    @Test("The daemon cleans what it is sent")
    func theDaemonCleansTheTitle() async throws {
        let (locations, work) = try temporary()
        let launcher = midTurn()
        let core = try core(launcher, locations: locations)
        let id = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "fix it"))
        let token = await mintedToken(launcher)
        let before = await core.agent(id)?.title

        _ = try await core.finishTurn(.init(token: token, outcome: "done", message: "Fixed.",
                                            prompts: [], title: "   \n  "))
        #expect(await core.agent(id)?.title == before)

        _ = try await core.finishTurn(.init(token: token, outcome: "done", message: "Fixed.",
                                            prompts: [], title: " Login\nredirect   fixed "))
        #expect(await core.agent(id)?.title == "Login redirect fixed")
        try await settle(core, id)
    }

    /// The flag is on the record, so a runtime title after a restart still does not
    /// replace the agent's.
    @Test("Who named it survives being written down")
    func titledByAgentIsKept() async throws {
        let (locations, work) = try temporary()
        let launcher = midTurn()
        let core = try core(launcher, locations: locations)
        let id = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "fix it"))
        _ = try await core.finishTurn(.init(token: await mintedToken(launcher),
                                            outcome: "done", message: "Fixed.",
                                            prompts: [], title: "Login redirect fixed"))
        try await settle(core, id)

        let reread = try await AgentStore(locations: locations).loadAll().agents.first { $0.id == id }
        #expect(reread?.title == "Login redirect fixed")
        #expect(reread?.titledByAgent == true)
    }
}
