import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// Putting a chat down to come back to (040), driven through the real daemon.
///
/// Parking is a mark on the record beside the ending, never a state: so every test
/// here checks the ending is untouched as well as the group.
@Suite("Parking a chat", .timeLimit(.minutes(1)))
struct ParkingTests {
    // MARK: Scaffolding

    private func temporary() throws -> (StoreLocations, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsParkingTests-\(UUID().uuidString)", isDirectory: true)
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

    /// A turn long enough to park in the middle of.
    private func midTurn() -> FakeLauncher {
        var script = FakeACPAgent.Script()
        script.turnDelay = .milliseconds(400)
        return FakeLauncher(script: script)
    }

    private func finished(_ work: URL, report: WorkReport? = nil) -> Agent {
        Agent(runtimeID: "copilot", cwd: work, title: "seed", state: .finished,
              endedReason: .endTurn, report: report)
    }

    private func transcriptCount(_ core: DaemonCore, _ id: UUID) async -> Int {
        (try? await core.transcript(.init(agentID: id)))?.total ?? -1
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

    private func call(_ core: DaemonCore, _ method: String, _ id: UUID) async throws {
        let answer = await core.handle(method: method,
                                       params: try JSONValue.encoding(DaemonAPI.AgentRequest(agentID: id)))
        guard case .success = answer else {
            Issue.record("\(method) did not succeed: \(answer)")
            return
        }
    }

    // MARK: US1 — park a chat I've finished with for now

    @Test func parkingAFinishedChatPutsItUnderParkedAndChangesNothingElse() async throws {
        let (locations, work) = try temporary()
        let seed = finished(work)
        let core = try await core(locations, seeded: [seed])
        let before = try #require(await core.agent(seed.id))
        let entries = await transcriptCount(core, seed.id)

        try await call(core, DaemonAPI.Method.agentsPark, seed.id)

        let after = try #require(await core.agent(seed.id))
        #expect(after.parking?.isParked == true)
        #expect(after.group(wantsEyes: false) == .parked)
        #expect(after.state == before.state)
        #expect(after.endedReason == before.endedReason)
        #expect(after.report == before.report)
        #expect(after.costToDate == before.costToDate)
        #expect(after.queuedPrompts == before.queuedPrompts)
        #expect(await transcriptCount(core, seed.id) == entries, "nothing is added to the conversation")
        #expect(await core.live[seed.id] == nil, "and no runtime was started")
    }

    @Test func parkingTwiceChangesNothingAndIsNoError() async throws {
        let (locations, work) = try temporary()
        let seed = finished(work)
        let core = try await core(locations, seeded: [seed])
        try await call(core, DaemonAPI.Method.agentsPark, seed.id)
        let first = try #require(await core.agent(seed.id)?.parking?.parkedAt)
        try await Task.sleep(for: .milliseconds(10))
        try await call(core, DaemonAPI.Method.agentsPark, seed.id)
        #expect(await core.agent(seed.id)?.parking?.parkedAt == first, "the first time stands")
        try await call(core, DaemonAPI.Method.agentsUnpark, seed.id)
        try await call(core, DaemonAPI.Method.agentsUnpark, seed.id)
        #expect(await core.agent(seed.id)?.parking == nil)
    }

    @Test func anArchivedChatCannotBeParked() async throws {
        let (locations, work) = try temporary()
        var seed = finished(work)
        seed.state = .archived
        seed.archivedReason = .byUser
        let core = try await core(locations, seeded: [seed])
        try await call(core, DaemonAPI.Method.agentsPark, seed.id)
        #expect(await core.agent(seed.id)?.parking == nil)
    }

    /// A report that wants the person leaves Needs attention and stops asking (FR-004).
    @Test func aParkedReportIsNoLongerANeed() async throws {
        let (locations, work) = try temporary()
        let seed = finished(work, report: WorkReport(outcome: .needsAnswer, message: "Which one?", at: Date()))
        let core = try await core(locations, seeded: [seed])
        #expect(await core.needs().contains { $0.agentID == seed.id })

        try await call(core, DaemonAPI.Method.agentsPark, seed.id)

        #expect(await !core.needs().contains { $0.agentID == seed.id })
        let agent = try #require(await core.agent(seed.id))
        #expect(agent.group(wantsEyes: false) == .parked)
        #expect(agent.report?.outcome == .needsAnswer, "the report is kept for when it comes back")
        let project = await core.allProjects().first { Project.standardize($0.folder) == work }
        #expect(project?.needsInput == false)
        #expect(project?.counts[.parked] == nil, "left out of the counts an older phone reads")
    }

    @Test func parkedSurvivesTheDaemonGoingAway() async throws {
        let (locations, work) = try temporary()
        let seed = finished(work)
        let first = try await core(locations, seeded: [seed])
        try await call(first, DaemonAPI.Method.agentsPark, seed.id)
        let parkedAt = try #require(await first.agent(seed.id)?.parking?.parkedAt)
        await first.saveTail?.value

        let second = try await core(locations)
        let reopened = try #require(await second.agent(seed.id))
        // The store keeps dates to its own precision, so to the second.
        let reread = try #require(reopened.parking?.parkedAt)
        #expect(abs(reread.timeIntervalSince(parkedAt)) < 1)
        #expect(reopened.group(wantsEyes: false) == .parked)
    }

    // MARK: US2 — come back to it

    @Test func unparkingPutsItBackWhereItsEndingSaysWithoutPromptingIt() async throws {
        let (locations, work) = try temporary()
        let seed = finished(work, report: WorkReport(outcome: .needsAnswer, message: "Which one?", at: Date()))
        let core = try await core(locations, seeded: [seed])
        try await call(core, DaemonAPI.Method.agentsPark, seed.id)
        let entries = await transcriptCount(core, seed.id)

        try await call(core, DaemonAPI.Method.agentsUnpark, seed.id)

        let agent = try #require(await core.agent(seed.id))
        #expect(agent.parking == nil)
        #expect(agent.group(wantsEyes: false) == .needsAttention)
        #expect(agent.state == .finished)
        #expect(await transcriptCount(core, seed.id) == entries)
        #expect(await core.live[seed.id] == nil, "the agent was not prompted")
        #expect(await core.needs().contains { $0.agentID == seed.id }, "and it asks again")
    }

    @Test func thePersonsPromptUnparksIt() async throws {
        let (locations, work) = try temporary()
        let seed = finished(work)
        let core = try await core(locations, seeded: [seed])
        try await call(core, DaemonAPI.Method.agentsPark, seed.id)

        let answer = await core.handle(method: DaemonAPI.Method.agentsPrompt,
                                       params: try JSONValue.encoding(DaemonAPI.PromptRequest(agentID: seed.id, text: "carry on")))
        guard case .success = answer else { Issue.record("prompt failed: \(answer)"); return }

        #expect(await core.agent(seed.id)?.parking == nil)
        try await settle(core, seed.id)
        #expect(await core.agent(seed.id)?.parking == nil, "and the turn it started does not park it again")
    }

    /// A workflow's prompt, the restart pick-up and the outcome question reach `prompt`
    /// directly. None is the person, so none unparks (FR-009).
    @Test func aPromptTheAppSendsLeavesItParked() async throws {
        let (locations, work) = try temporary()
        let seed = finished(work)
        let core = try await core(locations, seeded: [seed])
        try await call(core, DaemonAPI.Method.agentsPark, seed.id)

        try await core.prompt(.init(agentID: seed.id, text: "from a workflow"))
        #expect(await core.agent(seed.id)?.group(wantsEyes: false) == .parked, "parked while it runs")
        try await settle(core, seed.id)
        let agent = try #require(await core.agent(seed.id))
        #expect(agent.parking?.isParked == true)
        #expect(agent.group(wantsEyes: false) == .parked)
    }

    @Test func thePromptOfTheAppOverTheSocketLeavesItParked() async throws {
        let (locations, work) = try temporary()
        let seed = finished(work)
        let core = try await core(locations, seeded: [seed])
        try await call(core, DaemonAPI.Method.agentsPark, seed.id)

        let request = DaemonAPI.PromptRequest(agentID: seed.id, text: "how did it go?", from: .app)
        _ = await core.handle(method: DaemonAPI.Method.agentsPrompt, params: try JSONValue.encoding(request))
        #expect(await core.agent(seed.id)?.parking?.isParked == true)
        try await settle(core, seed.id)
    }

    @Test func archivingUnparksItAndUnarchivingDoesNotParkItAgain() async throws {
        let (locations, work) = try temporary()
        let seed = finished(work)
        let core = try await core(locations, seeded: [seed])
        try await call(core, DaemonAPI.Method.agentsPark, seed.id)

        try await core.archive(seed.id)
        let archived = try #require(await core.agent(seed.id))
        #expect(archived.parking == nil)
        #expect(archived.group(wantsEyes: false) == .archived)

        try await core.unarchive(seed.id)
        let back = try #require(await core.agent(seed.id))
        #expect(back.parking == nil)
        #expect(back.group(wantsEyes: false) == .finished)
    }

    @Test func aParkedChatStillHoldsItsProjectsSpending() async throws {
        let (locations, work) = try temporary()
        var seed = finished(work)
        seed.costToDate = ["USD": 1.25]
        let core = try await core(locations, seeded: [seed])
        try await call(core, DaemonAPI.Method.agentsPark, seed.id)
        let project = await core.allProjects().first { Project.standardize($0.folder) == work }
        #expect(project?.costToDate["USD"] == 1.25)
    }

    // MARK: US3 — park a chat that is still working

    @Test func parkingAWorkingChatLetsTheTurnFinishThenParksIt() async throws {
        let (locations, work) = try temporary()
        let launcher = midTurn()
        let core = try await core(locations, launcher: launcher)
        let id = try await core.start(.init(runtimeID: "copilot", cwd: work, prompt: "go"))

        try await call(core, DaemonAPI.Method.agentsPark, id)
        let marked = try #require(await core.agent(id))
        guard case .whenTurnEnds = marked.parking else {
            Issue.record("expected the chat to be marked, got \(String(describing: marked.parking))")
            return
        }
        #expect(marked.group(wantsEyes: false) == .running, "still under Working until the turn ends")

        try await settle(core, id)
        let agent = try #require(await core.agent(id))
        #expect(agent.parking?.isParked == true)
        #expect(agent.group(wantsEyes: false) == .parked)
        #expect(agent.state == .finished, "it ran to its end, nothing was cut off")
        #expect(agent.isUnread == false)
    }

    @Test func aTurnThatEndsAskingForThePersonParksWithoutANeed() async throws {
        let (locations, work) = try temporary()
        let launcher = midTurn()
        let core = try await core(locations, launcher: launcher)
        let id = try await core.start(.init(runtimeID: "copilot", cwd: work, prompt: "go"))

        try await call(core, DaemonAPI.Method.agentsPark, id)
        _ = try await core.reportOutcome(.init(token: await mintedToken(launcher),
                                               outcome: "needs_answer", message: "Which index?"))
        try await settle(core, id)

        let agent = try #require(await core.agent(id))
        #expect(agent.group(wantsEyes: false) == .parked)
        #expect(agent.report?.outcome == .needsAnswer)
        #expect(await !core.needs().contains { $0.agentID == id })
    }

    @Test func aStoppedTurnParksToo() async throws {
        let (locations, work) = try temporary()
        let core = try await core(locations, launcher: midTurn())
        let id = try await core.start(.init(runtimeID: "copilot", cwd: work, prompt: "go"))

        try await call(core, DaemonAPI.Method.agentsPark, id)
        try await core.stop(id)
        try await settle(core, id)

        let agent = try #require(await core.agent(id))
        #expect(agent.state == .stopped)
        #expect(agent.group(wantsEyes: false) == .parked)
    }

    @Test func unparkingBeforeTheTurnEndsWithdrawsTheMark() async throws {
        let (locations, work) = try temporary()
        let core = try await core(locations, launcher: midTurn())
        let id = try await core.start(.init(runtimeID: "copilot", cwd: work, prompt: "go"))

        try await call(core, DaemonAPI.Method.agentsPark, id)
        try await call(core, DaemonAPI.Method.agentsUnpark, id)
        try await settle(core, id)

        let agent = try #require(await core.agent(id))
        #expect(agent.parking == nil)
        #expect(agent.group(wantsEyes: false) != .parked)
    }

    @Test func thePersonsPromptMidTurnWithdrawsTheMark() async throws {
        let (locations, work) = try temporary()
        let core = try await core(locations, launcher: midTurn())
        let id = try await core.start(.init(runtimeID: "copilot", cwd: work, prompt: "go"))

        try await call(core, DaemonAPI.Method.agentsPark, id)
        _ = await core.handle(method: DaemonAPI.Method.agentsPrompt,
                              params: try JSONValue.encoding(DaemonAPI.PromptRequest(agentID: id, text: "and then")))
        #expect(await core.agent(id)?.parking == nil)
        try await settle(core, id)
        #expect(await core.agent(id)?.group(wantsEyes: false) != .parked)
    }
}
