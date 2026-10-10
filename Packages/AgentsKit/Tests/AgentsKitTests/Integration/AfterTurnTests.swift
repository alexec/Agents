import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// An agent asking, with request_archive, for the person to archive it once that turn
/// is over (#584) — driven through the real daemon. An ask to be archived from a session no
/// workflow is running is refused whole (#433 covers the runs that may).
///
/// What these are for is the shape of the promise: the ask takes effect only once the
/// turn has ended as asked, is refused whole when it contradicts the outcome, and is
/// dropped when the person moves the work on first.
@Suite("Asking to be archived at the end of a turn", .timeLimit(.minutes(1)))
struct AfterTurnTests {
    private func temporary() throws -> (StoreLocations, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsAfterTurnTests-\(UUID().uuidString)", isDirectory: true)
        let work = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        return (StoreLocations(root: root), Project.standardize(work))
    }

    private func core(_ launcher: FakeLauncher, locations: StoreLocations) throws -> DaemonCore {
        DaemonCore(store: try AgentStore(locations: locations),
                   locations: locations,
                   discovery: .findsEverything,
                   launcher: launcher)
    }

    /// A turn long enough to call a tool in the middle of.
    private func midTurn() -> FakeLauncher {
        var script = FakeACPAgent.Script()
        script.turnDelay = .milliseconds(400)
        return FakeLauncher(script: script)
    }

    private func mintedToken(_ launcher: FakeLauncher) async -> String {
        await eventuallySome("the runtime was handed its token") {
            let minted = MintedMCPToken.from(sessionParams: await launcher.lastAgent?.newSessionParams)
            return minted.isEmpty ? nil : minted
        } ?? ""
    }

    /// Wait until the turn is over, nothing is queued, and the runtime has been let go.
    private func settle(_ core: DaemonCore, _ id: UUID) async throws {
        let deadline = ContinuousClock.now.advanced(by: Eventually.timeout)
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
    private func finish(_ core: DaemonCore, _ launcher: FakeLauncher, _ outcome: String,
                        afterwards: String?) async throws -> String {
        try await core.finishTurn(.init(token: await mintedToken(launcher), outcome: outcome,
                                        message: "Merged, and cleaned up.", prompts: [],
                                        afterwards: afterwards))
    }

    // MARK: Request to archive

    @Test func aRequestMarksTheSessionWhenTheTurnEnds() async throws {
        let (locations, work) = try temporary()
        let launcher = midTurn()
        let core = try core(launcher, locations: locations)
        let id = try await core.start(.init(runtimeID: "cursor", cwd: work, prompt: "go"))

        let reply = try await finish(core, launcher, "partly_done", afterwards: "request_archive")
        #expect(reply.contains("will be asked to archive"))
        #expect(await core.agent(id)?.archiveRequest == nil, "nothing happens until the turn is over")
        #expect(await core.agent(id)?.afterTurn == .requestArchive)

        try await settle(core, id)
        let agent = try #require(await core.agent(id))
        #expect(agent.state == .finished, "the turn ran to its end")
        #expect(agent.asksToArchive)
        // Partly done still says so under Needs you; the mark is beside it (#584).
        #expect(agent.group(wantsEyes: false) == .needsAttention)
        #expect(agent.afterTurn == nil)
    }

    /// The person's prompt drops the ask the moment it is sent.
    @Test func thePersonsPromptDropsTheAsk() async throws {
        let (locations, work) = try temporary()
        let launcher = midTurn()
        let core = try core(launcher, locations: locations)
        let id = try await core.start(.init(runtimeID: "cursor", cwd: work, prompt: "go"))

        try await finish(core, launcher, "done", afterwards: "request_archive")
        _ = await core.handle(method: DaemonAPI.Method.agentsPrompt,
                              params: try JSONValue.encoding(DaemonAPI.PromptRequest(agentID: id, text: "and then")))
        #expect(await core.agent(id)?.afterTurn == nil)

        try await settle(core, id)
        #expect(await core.agent(id)?.asksToArchive == false)
    }

    @Test func aStopDropsTheAsk() async throws {
        let (locations, work) = try temporary()
        let launcher = midTurn()
        let core = try core(launcher, locations: locations)
        let id = try await core.start(.init(runtimeID: "cursor", cwd: work, prompt: "go"))

        try await finish(core, launcher, "done", afterwards: "request_archive")
        try await core.stop(id)
        try await settle(core, id)

        let agent = try #require(await core.agent(id))
        #expect(agent.state == .stopped)
        #expect(agent.afterTurn == nil)
        #expect(agent.archiveRequest == nil)
    }

    // MARK: A later account

    /// Since #481 the ask is request_archive's to make, so a later finish_turn without
    /// one keeps it — while its ending still goes with it.
    @Test func aLaterCallWithoutAfterwardsKeepsTheAsk() async throws {
        let (locations, work) = try temporary()
        let launcher = midTurn()
        let core = try core(launcher, locations: locations)
        let id = try await core.start(.init(runtimeID: "cursor", cwd: work, prompt: "go"))

        try await finish(core, launcher, "done", afterwards: "request_archive")
        try await finish(core, launcher, "done", afterwards: nil)
        #expect(await core.agent(id)?.afterTurn == .requestArchive)

        try await settle(core, id)
        #expect(await core.agent(id)?.asksToArchive == true)
    }

    /// And an ending that does not go with it drops it, telling the agent.
    @Test func aLaterEndingThatDoesNotGoWithTheAskDropsIt() async throws {
        let (locations, work) = try temporary()
        let launcher = midTurn()
        let core = try core(launcher, locations: locations)
        let id = try await core.start(.init(runtimeID: "cursor", cwd: work, prompt: "go"))

        _ = try await core.askAfterTurn(.init(token: await mintedToken(launcher), afterwards: "request_archive"))
        let reply = try await finish(core, launcher, "stuck", afterwards: nil)
        #expect(reply.contains("Your ask to be archived is dropped"))
        #expect(await core.agent(id)?.afterTurn == nil)
        try await settle(core, id)
        #expect(await core.agent(id)?.archiveRequest == nil)
    }

    // MARK: request_archive with no id (#481)

    /// Asked mid-turn and never followed by finish_turn: the turn's worked-out ending
    /// goes with the request, and the session asks when the turn ends.
    @Test func requestArchiveOnItselfAsksWhenTheTurnEnds() async throws {
        let (locations, work) = try temporary()
        let launcher = midTurn()
        let core = try core(launcher, locations: locations)
        let id = try await core.start(.init(runtimeID: "cursor", cwd: work, prompt: "go"))

        let reply = try await core.askAfterTurn(.init(token: await mintedToken(launcher), afterwards: "request_archive"))
        #expect(reply.contains("will be asked to archive"))
        #expect(await core.agent(id)?.archiveRequest == nil, "nothing happens until the turn is over")

        try await settle(core, id)
        let agent = try #require(await core.agent(id))
        #expect(agent.state == .finished)
        #expect(agent.asksToArchive)
    }

    /// Its own id is the same ask as none.
    @Test func requestArchiveWithItsOwnIdIsTheSameAsk() async throws {
        let (locations, work) = try temporary()
        let launcher = midTurn()
        let core = try core(launcher, locations: locations)
        let id = try await core.start(.init(runtimeID: "cursor", cwd: work, prompt: "go"))

        let reply = try await core.requestArchiveHelper(.init(token: await mintedToken(launcher), agentID: id.uuidString))
        #expect(reply.contains("will be asked to archive"))
        #expect(await core.agent(id)?.afterTurn == .requestArchive)
        try await settle(core, id)
    }

    /// A wait this turn and a request do not go together: the wait first refuses the
    /// request; the request first is dropped by the wait, which says so.
    @Test func aWaitAndARequestDoNotGoTogether() async throws {
        let (locations, work) = try temporary()
        let launcher = midTurn()
        let core = try core(launcher, locations: locations)
        let id = try await core.start(.init(runtimeID: "cursor", cwd: work, prompt: "go"))
        let token = await mintedToken(launcher)

        _ = try await core.askAfterTurn(.init(token: token, afterwards: "request_archive"))
        let waiting = try await core.waitOn(.init(token: token, untilMinutes: 5, message: "CI is running."))
        #expect(waiting.contains("Your ask to be archived is dropped"))
        #expect(await core.agent(id)?.afterTurn == nil)
        #expect(await core.agent(id)?.report?.outcome == .blocked)

        let error = await #expect(throws: JSONRPCError.self) {
            _ = try await core.askAfterTurn(.init(token: token, afterwards: "request_archive"))
        }
        #expect(error?.message.contains("this turn ended blocked") == true)
        try await settle(core, id)
        #expect(await core.agent(id)?.archiveRequest == nil)
    }

    /// Archiving itself is a workflow's run's, and only where its workflow allows.
    @Test func archiveAgentOnItselfIsRefusedOutsideARun() async throws {
        let (locations, work) = try temporary()
        let launcher = midTurn()
        let core = try core(launcher, locations: locations)
        let id = try await core.start(.init(runtimeID: "cursor", cwd: work, prompt: "go"))

        let error = await #expect(throws: JSONRPCError.self) {
            _ = try await core.askAfterTurn(.init(token: await mintedToken(launcher), afterwards: "archive"))
        }
        #expect(error?.message == DaemonCore.cannotArchiveItself)
        #expect(await core.agent(id)?.afterTurn == nil)
        try await settle(core, id)
    }

    /// The older door cannot ask, and a later account through it is the whole account.
    @Test func aLaterReportThroughTheOlderNameClearsTheAsk() async throws {
        let (locations, work) = try temporary()
        let launcher = midTurn()
        let core = try core(launcher, locations: locations)
        let id = try await core.start(.init(runtimeID: "cursor", cwd: work, prompt: "go"))

        try await finish(core, launcher, "done", afterwards: "request_archive")
        _ = try await core.reportOutcome(.init(token: await mintedToken(launcher),
                                               outcome: "stuck", message: "The merge failed."))
        try await settle(core, id)
        #expect(await core.agent(id)?.state == .finished)
        #expect(await core.agent(id)?.afterTurn == nil)
        #expect(await core.agent(id)?.archiveRequest == nil)
    }

    // MARK: Refused whole

    @Test(arguments: [("request_archive", "needs_answer"), ("request_archive", "stuck"),
                      ("request_archive", "blocked"), ("later", "done"),
                      // Only a workflow's run may archive itself, when its workflow allows (#433).
                      ("archive", "done")])
    func aPairingThatContradictsTheOutcomeRecordsNothing(_ afterwards: String, _ outcome: String) async throws {
        let (locations, work) = try temporary()
        let launcher = midTurn()
        let core = try core(launcher, locations: locations)
        let id = try await core.start(.init(runtimeID: "cursor", cwd: work, prompt: "go"))

        let error = await #expect(throws: JSONRPCError.self) {
            _ = try await core.finishTurn(.init(token: await mintedToken(launcher), outcome: outcome,
                                                message: "Over.", prompts: [],
                                                waitingOn: outcome == "blocked" ? [] : nil,
                                                checkAgainInMinutes: outcome == "blocked" ? 5 : nil,
                                                afterwards: afterwards))
        }
        #expect(error?.code == JSONRPCError.invalidParams)
        #expect(error?.message.hasPrefix("Nothing was recorded") == true)
        let agent = try #require(await core.agent(id))
        #expect(agent.report == nil)
        #expect(agent.afterTurn == nil)
        try await settle(core, id)
    }


    // MARK: The wire

    /// A helper started from an older binary sends no `afterwards`, and its call still lands.
    @Test func anOldRequestWithoutTheFieldDecodes() throws {
        let old = #"{"token":"t","outcome":"done","message":"Done.","prompts":[]}"#
        let request = try JSONDecoder().decode(DaemonAPI.FinishTurnRequest.self, from: Data(old.utf8))
        #expect(request.afterwards == nil)
    }
}
