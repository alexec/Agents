import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// An agent saying, at the end, how the work actually went.
///
/// The older name for the outcome half of `finish_turn`, still served (023). These
/// are the daemon's half of it, and they are never edited: that a
/// report moves the agent into the group its outcome names, that the person's next
/// prompt settles it, and that a report nobody can honour is refused in a sentence
/// rather than a code.
@Suite("Reporting how it went", .timeLimit(.minutes(1)))
struct OutcomeReportTests {
    private func temporary() throws -> (StoreLocations, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsOutcomeTests-\(UUID().uuidString)", isDirectory: true)
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

    @discardableResult
    private func report(_ core: DaemonCore, _ launcher: FakeLauncher,
                        _ outcome: String, _ message: String) async throws -> String {
        try await core.reportOutcome(.init(token: await mintedToken(launcher),
                                           outcome: outcome, message: message))
    }

    // MARK: The question that was hiding under a tick

    /// US1, whole. Nothing here opens the conversation.
    @Test func anAgentThatNeedsAnAnswerIsFoundFromTheListAlone() async throws {
        let (locations, work) = try temporary()
        let launcher = midTurn()
        let core = try core(launcher, locations: locations)
        let id = try await core.start(.init(runtimeID: "copilot", cwd: work, prompt: "go"))

        let note = try await report(core, launcher, "needs_answer",
                                    "Drop the old index first, or migrate it?")
        // The agent is told what became of it, in a sentence.
        #expect(note.contains("Needs attention"))

        try await settle(core, id)
        let agent = try #require(await core.agent(id))
        #expect(agent.group(wantsEyes: false) == .needsAttention)
        #expect(agent.report?.outcome == .needsAnswer)
        // Its own question, which is what the row shows.
        #expect(agent.report?.message == "Drop the old index first, or migrate it?")
        // And the project it belongs to says somebody is wanted.
        let project = await core.allProjects().first { Project.standardize($0.folder) == Project.standardize(work) }
        #expect(project?.needsInput == true)
    }

    @Test func anAgentThatSaysItIsDoneIsComplete() async throws {
        let (locations, work) = try temporary()
        let launcher = midTurn()
        let core = try core(launcher, locations: locations)
        let id = try await core.start(.init(runtimeID: "copilot", cwd: work, prompt: "go"))

        try await report(core, launcher, "done", "Renamed 14 call sites; tests pass.")
        try await settle(core, id)

        let agent = try #require(await core.agent(id))
        #expect(agent.group(wantsEyes: false) == .finished)
        #expect(agent.report?.outcome == .done)
        #expect(agent.needsAPerson == false)
        let project = await core.allProjects().first { Project.standardize($0.folder) == Project.standardize(work) }
        #expect(project?.needsInput == false)
    }

    /// An agent that reports twice in one turn has changed its mind. The last stands;
    /// the earlier one is not history worth keeping (FR-005).
    @Test func asecondReportInTheSameTurnReplacesTheFirst() async throws {
        let (locations, work) = try temporary()
        let launcher = midTurn()
        let core = try core(launcher, locations: locations)
        let id = try await core.start(.init(runtimeID: "copilot", cwd: work, prompt: "go"))

        try await report(core, launcher, "partly_done", "Five of six.")
        try await report(core, launcher, "done", "Got the sixth after all.")

        let agent = try #require(await core.agent(id))
        #expect(agent.report?.outcome == .done)
        #expect(agent.report?.message == "Got the sixth after all.")
    }

    /// It is an account of the turn it came from, and a stale one is worse than none.
    @Test func thePersonsNextPromptClearsIt() async throws {
        let (locations, work) = try temporary()
        let launcher = midTurn()
        let core = try core(launcher, locations: locations)
        let id = try await core.start(.init(runtimeID: "copilot", cwd: work, prompt: "go"))

        try await report(core, launcher, "needs_answer", "Which index?")
        try await settle(core, id)
        #expect(await core.agent(id)?.report != nil)

        try await core.prompt(.init(agentID: id, text: "the old one"))
        await eventually("the report went with the new prompt") {
            await core.agent(id)?.report == nil
        }
        #expect(await core.agent(id)?.report == nil)
        #expect(await core.agent(id)?.outcomeAsked == false)
    }

    /// Archiving is a decision, and it wins (FR-018).
    @Test func archivingTakesItOutOfNeedsAttentionWhateverItSaid() async throws {
        let (locations, work) = try temporary()
        let launcher = midTurn()
        let core = try core(launcher, locations: locations)
        let id = try await core.start(.init(runtimeID: "copilot", cwd: work, prompt: "go"))

        try await report(core, launcher, "needs_answer", "Which index?")
        try await settle(core, id)
        #expect(await core.agent(id)?.group(wantsEyes: false) == .needsAttention)

        try await core.archive(id)
        let agent = try #require(await core.agent(id))
        #expect(agent.group(wantsEyes: false) == .archived)
        // The record is kept. Archiving changes the group, not what was said.
        #expect(agent.report?.outcome == .needsAnswer)
    }

    /// The list and the transcript have to agree about the same turn (FR-015).
    @Test func theReportIsAlsoTheLastThingInTheConversation() async throws {
        let (locations, work) = try temporary()
        let launcher = midTurn()
        let core = try core(launcher, locations: locations)
        let id = try await core.start(.init(runtimeID: "copilot", cwd: work, prompt: "go"))

        try await report(core, launcher, "stuck", "No signing certificate on this machine.")
        try await settle(core, id)

        let reported = try await core.transcript(.init(agentID: id)).entries
            .compactMap { entry -> WorkReport? in
                if case .workReported(let report) = entry.kind { return report }
                return nil
            }
        #expect(reported.map(\.outcome) == [.stuck])
        #expect(reported.first?.message == "No signing certificate on this machine.")
    }

    // MARK: The other three outcomes

    @Test func partlyDoneAndStuckWantAPersonAndNothingToDoDoesNot() async throws {
        for (wire, outcome) in [("partly_done", WorkOutcome.partlyDone),
                                ("stuck", .stuck),
                                ("nothing_to_do", .nothingToDo)] {
            let (locations, work) = try temporary()
            let launcher = midTurn()
            let core = try core(launcher, locations: locations)
            let id = try await core.start(.init(runtimeID: "copilot", cwd: work, prompt: "go"))

            try await report(core, launcher, wire, "what the agent said about \(wire)")
            try await settle(core, id)

            let agent = try #require(await core.agent(id))
            #expect(agent.report?.outcome == outcome)
            #expect(agent.group(wantsEyes: false) == (outcome.needsAPerson ? .needsAttention : .finished))
            // Whatever the outcome, the row reads the agent's own words.
            #expect(agent.report?.message == "what the agent said about \(wire)")
        }
    }

    // MARK: What is refused, and how it reads

    /// A helper left behind by a dead runtime cannot post into a conversation it is no
    /// longer part of.
    @Test func aTokenThatNoLongerSpeaksForAnAgentIsRefused() async throws {
        let (locations, work) = try temporary()
        let launcher = FakeLauncher()
        let core = try core(launcher, locations: locations)
        _ = try await core.start(.init(runtimeID: "copilot", cwd: work, prompt: "go"))

        let error = await #expect(throws: JSONRPCError.self) {
            _ = try await core.reportOutcome(.init(token: "not-a-token", outcome: "done",
                                                   message: "all done"))
        }
        #expect(error?.code == DaemonAPI.Failure.noSuchAgent)
        #expect(error?.message.contains("not open any more") == true)
    }

    @Test func anEmptyMessageAndAnUnknownOutcomeAreBothRefused() async throws {
        let (locations, work) = try temporary()
        let launcher = midTurn()
        let core = try core(launcher, locations: locations)
        let id = try await core.start(.init(runtimeID: "copilot", cwd: work, prompt: "go"))
        let token = await mintedToken(launcher)

        let unknown = await #expect(throws: JSONRPCError.self) {
            _ = try await core.reportOutcome(.init(token: token, outcome: "succeeded",
                                                   message: "all good"))
        }
        #expect(unknown?.code == JSONRPCError.invalidParams)
        #expect(unknown?.message.contains("needs_answer") == true)

        let empty = await #expect(throws: JSONRPCError.self) {
            _ = try await core.reportOutcome(.init(token: token, outcome: "done", message: "  "))
        }
        #expect(empty?.code == JSONRPCError.invalidParams)
        #expect(empty?.message.contains("how it went") == true)

        // Neither left anything behind.
        #expect(await core.agent(id)?.report == nil)
    }

    /// A person must not be told the work is settled while the app is still holding a
    /// question for them (FR-008).
    @Test func aReportWhileAQuestionIsOutstandingIsRefused() async throws {
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
            _ = try await core.reportOutcome(.init(token: await mintedToken(launcher),
                                                   outcome: "done", message: "all done"))
        }
        #expect(error?.code == JSONRPCError.invalidParams)
        #expect(error?.message.contains("question waiting") == true)
        #expect(await core.agent(id)?.report == nil)
    }
}
