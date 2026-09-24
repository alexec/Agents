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
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
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

    /// US1, whole: one call, and the agent reads as a report and a row of chips.
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
        #expect(agent.suggestedPrompts.map(\.label) == ["A", "B"])
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
        #expect(both.contains("2 shown above the prompt"))

        let alone = try await finish(core, launcher, "done", "All done.")
        #expect(alone.hasPrefix("Noted."))
        #expect(!alone.contains("shown above the prompt"))
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
}
