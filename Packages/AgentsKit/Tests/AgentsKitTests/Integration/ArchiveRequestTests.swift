import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// An agent's request to archive a session, waiting for the person's OK (#584), driven
/// through the real daemon.
///
/// The request is a mark on the record beside the ending, never a state or a group: so
/// every test here checks the ending and the group are untouched as well.
@Suite("Asking to archive a session", .timeLimit(.minutes(1)))
struct ArchiveRequestTests {
    // MARK: Scaffolding

    private func temporary() throws -> (StoreLocations, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsArchiveRequestTests-\(UUID().uuidString)", isDirectory: true)
        let work = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        return (StoreLocations(root: root), Project.standardize(work))
    }

    private func core(_ locations: StoreLocations, seeded: [Agent] = [],
                      launcher: FakeLauncher = FakeLauncher(script: .init())) async throws -> DaemonCore {
        let store = try AgentStore(locations: locations)
        for agent in seeded { try await store.save(agent) }
        let core = DaemonCore(store: store, locations: locations,
                              discovery: .findsEverything, launcher: launcher)
        await core.loadFromDisk()
        return core
    }

    /// A turn long enough to ask in the middle of.
    private func midTurn() -> FakeLauncher {
        var script = FakeACPAgent.Script()
        script.turnDelay = .milliseconds(400)
        return FakeLauncher(script: script)
    }

    private func finished(_ work: URL, report: WorkReport? = nil) -> Agent {
        Agent(runtimeID: "cursor", cwd: work, title: "seed", state: .finished,
              endedReason: .endTurn, report: report)
    }

    private func transcriptCount(_ core: DaemonCore, _ id: UUID) async -> Int {
        (try? await core.transcript(.init(agentID: id)))?.total ?? -1
    }

    private func mintedToken(_ launcher: FakeLauncher) async -> String {
        await eventuallySome("the runtime was handed its token") {
            let minted = MintedMCPToken.from(sessionParams: await launcher.lastAgent?.newSessionParams)
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

    // MARK: Asked when settled

    @Test func askingOnAFinishedSessionMarksItAndChangesNothingElse() async throws {
        let (locations, work) = try temporary()
        let seed = finished(work)
        let core = try await core(locations, seeded: [seed])
        let before = try #require(await core.agent(seed.id))
        let entries = await transcriptCount(core, seed.id)

        try await core.requestArchive(seed.id)

        let after = try #require(await core.agent(seed.id))
        #expect(after.asksToArchive)
        #expect(after.group(wantsEyes: false) == .finished, "a mark, not a group: still under Done")
        #expect(after.state == before.state)
        #expect(after.endedReason == before.endedReason)
        #expect(after.report == before.report)
        #expect(after.queuedPrompts == before.queuedPrompts)
        #expect(await transcriptCount(core, seed.id) == entries, "nothing is added to the conversation")
        #expect(await core.live[seed.id] == nil, "and no runtime was started")
    }

    @Test func askingTwiceKeepsTheFirstTime() async throws {
        let (locations, work) = try temporary()
        let seed = finished(work)
        let core = try await core(locations, seeded: [seed])
        try await core.requestArchive(seed.id)
        let first = try #require(await core.agent(seed.id)?.archiveRequest?.requestedAt)
        try await Task.sleep(for: .milliseconds(10))
        try await core.requestArchive(seed.id)
        #expect(await core.agent(seed.id)?.archiveRequest?.requestedAt == first, "the first time stands")
    }

    @Test func anArchivedSessionIsNotAsked() async throws {
        let (locations, work) = try temporary()
        var seed = finished(work)
        seed.state = .archived
        seed.archivedReason = .byUser
        let core = try await core(locations, seeded: [seed])
        try await core.requestArchive(seed.id)
        #expect(await core.agent(seed.id)?.archiveRequest == nil)
    }

    @Test func theRequestSurvivesTheDaemonGoingAway() async throws {
        let (locations, work) = try temporary()
        let seed = finished(work)
        let first = try await core(locations, seeded: [seed])
        try await first.requestArchive(seed.id)
        let at = try #require(await first.agent(seed.id)?.archiveRequest?.requestedAt)
        await first.saveTail?.value

        let second = try await core(locations)
        let reopened = try #require(await second.agent(seed.id))
        // The store keeps dates to its own precision, so to the second.
        let reread = try #require(reopened.archiveRequest?.requestedAt)
        #expect(abs(reread.timeIntervalSince(at)) < 1)
        #expect(reopened.group(wantsEyes: false) == .finished)
    }

    // MARK: Taken away

    @Test func thePersonsPromptTakesTheRequestAway() async throws {
        let (locations, work) = try temporary()
        let seed = finished(work)
        let core = try await core(locations, seeded: [seed])
        try await core.requestArchive(seed.id)

        let answer = await core.handle(method: DaemonAPI.Method.agentsPrompt,
                                       params: try JSONValue.encoding(DaemonAPI.PromptRequest(agentID: seed.id, text: "carry on")))
        guard case .success = answer else { Issue.record("prompt failed: \(answer)"); return }

        #expect(await core.agent(seed.id)?.archiveRequest == nil)
        try await settle(core, seed.id)
        #expect(await core.agent(seed.id)?.archiveRequest == nil, "and the turn it started does not ask again")
    }

    /// A workflow's prompt, the restart pick-up and the outcome question reach `prompt`
    /// directly. None is the person, so none answers the request.
    @Test func aPromptTheAppSendsLeavesTheRequest() async throws {
        let (locations, work) = try temporary()
        let seed = finished(work)
        let core = try await core(locations, seeded: [seed])
        try await core.requestArchive(seed.id)

        try await core.prompt(.init(agentID: seed.id, text: "from a workflow"))
        try await settle(core, seed.id)
        let agent = try #require(await core.agent(seed.id))
        #expect(agent.asksToArchive)
        #expect(agent.group(wantsEyes: false) == .finished)
    }

    @Test func archivingTakesItAwayAndUnarchivingDoesNotPutItBack() async throws {
        let (locations, work) = try temporary()
        let seed = finished(work)
        let core = try await core(locations, seeded: [seed])
        try await core.requestArchive(seed.id)

        try await core.archive(seed.id)
        let archived = try #require(await core.agent(seed.id))
        #expect(archived.archiveRequest == nil)
        #expect(archived.group(wantsEyes: false) == .archived)

        try await core.unarchive(seed.id)
        let back = try #require(await core.agent(seed.id))
        #expect(back.archiveRequest == nil)
        #expect(back.group(wantsEyes: false) == .finished)
    }

    // MARK: Asked while working

    @Test func askingWhileWorkingLetsTheTurnFinishThenMarksIt() async throws {
        let (locations, work) = try temporary()
        let core = try await core(locations, launcher: midTurn())
        let id = try await core.start(.init(runtimeID: "cursor", cwd: work, prompt: "go"))

        try await core.requestArchive(id)
        let marked = try #require(await core.agent(id))
        guard case .whenTurnEnds = marked.archiveRequest else {
            Issue.record("expected the session to be set to ask, got \(String(describing: marked.archiveRequest))")
            return
        }
        #expect(!marked.asksToArchive, "nothing shown until the turn ends")

        try await settle(core, id)
        let agent = try #require(await core.agent(id))
        #expect(agent.asksToArchive)
        #expect(agent.group(wantsEyes: false) == .finished)
        #expect(agent.state == .finished, "it ran to its end, nothing was cut off")
    }

    /// The session wants the person again, so the request goes (#584).
    @Test func aTurnThatEndsNeedingThePersonDropsTheRequest() async throws {
        let (locations, work) = try temporary()
        let launcher = midTurn()
        let core = try await core(locations, launcher: launcher)
        let id = try await core.start(.init(runtimeID: "cursor", cwd: work, prompt: "go"))

        try await core.requestArchive(id)
        _ = try await core.reportOutcome(.init(token: await mintedToken(launcher),
                                               outcome: "needs_answer", message: "Which index?"))
        try await settle(core, id)

        let agent = try #require(await core.agent(id))
        #expect(agent.archiveRequest == nil)
        #expect(agent.group(wantsEyes: false) == .needsAttention)
        #expect(await core.needs().contains { $0.agentID == id })
    }

    @Test func aTurnThePersonStoppedStillAsks() async throws {
        let (locations, work) = try temporary()
        let core = try await core(locations, launcher: midTurn())
        let id = try await core.start(.init(runtimeID: "cursor", cwd: work, prompt: "go"))

        try await core.requestArchive(id)
        try await core.stop(id)
        try await settle(core, id)

        let agent = try #require(await core.agent(id))
        #expect(agent.state == .stopped)
        #expect(agent.group(wantsEyes: false) == .stopped)
        #expect(agent.asksToArchive)
    }

    @Test func thePersonsPromptMidTurnWithdrawsTheRequest() async throws {
        let (locations, work) = try temporary()
        let core = try await core(locations, launcher: midTurn())
        let id = try await core.start(.init(runtimeID: "cursor", cwd: work, prompt: "go"))

        try await core.requestArchive(id)
        _ = await core.handle(method: DaemonAPI.Method.agentsPrompt,
                              params: try JSONValue.encoding(DaemonAPI.PromptRequest(agentID: id, text: "and then")))
        #expect(await core.agent(id)?.archiveRequest == nil)
        try await settle(core, id)
        #expect(await core.agent(id)?.archiveRequest == nil)
    }

    // MARK: The event

    private func events(_ core: DaemonCore, _ id: UUID) async -> [String] {
        await core.eventLog.events
            .filter { $0.details["agent"] == id.uuidString
                && ["agent.archive_requested", "agent.archived"].contains($0.name) }
            .map(\.name)
    }

    @Test func askingOnASettledSessionRaisesTheEventOnce() async throws {
        let (locations, work) = try temporary()
        let seed = finished(work)
        let core = try await core(locations, seeded: [seed])
        try await core.requestArchive(seed.id)
        try await core.requestArchive(seed.id)
        #expect(await events(core, seed.id) == ["agent.archive_requested"])
    }

    @Test func aWorkingSessionRaisesTheEventWhenItsTurnEnds() async throws {
        let (locations, work) = try temporary()
        let core = try await core(locations, launcher: midTurn())
        let id = try await core.start(.init(runtimeID: "cursor", cwd: work, prompt: "go"))
        try await core.requestArchive(id)
        #expect(!(await events(core, id)).contains("agent.archive_requested"), "not while only set to ask")
        try await settle(core, id)
        #expect(await events(core, id) == ["agent.archive_requested"])
    }

    @Test func archivingRaisesAgentArchivedByYouAndNotAgainWhenAlreadyArchived() async throws {
        let (locations, work) = try temporary()
        let seed = finished(work)
        let core = try await core(locations, seeded: [seed])
        try await core.archive(seed.id)
        try await core.archive(seed.id)
        let archived = await core.eventLog.events.filter {
            $0.name == "agent.archived" && $0.details["agent"] == seed.id.uuidString
        }
        #expect(archived.count == 1)
        #expect(archived.first?.details["by"] == "you")
        try await core.unarchive(seed.id)
        #expect(await events(core, seed.id) == ["agent.archived"], "unarchiving raises neither")
    }
}
